// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import AVFAudio
import Combine
import CoreBluetooth

final class WhisperViewModel: ObservableObject {
    typealias Remote = ComboFactory.Publisher.Remote
    typealias Transport = ComboFactory.Publisher
    
	final class Candidate: Identifiable, Comparable {
		private(set) var id: String
		private(set) var remote: Remote
		var info: WhisperProtocol.ClientInfo
		var isPending: Bool
		var joinDate: Date?
		private(set) var created: Date

		init(remote: Remote, info: WhisperProtocol.ClientInfo, isPending: Bool) {
			self.id = remote.id
			self.remote = remote
			self.info = info
			self.isPending = isPending
			self.joinDate = nil
			self.created = Date.now
		}

		// compare by id
		static func == (lhs: WhisperViewModel.Candidate, rhs: WhisperViewModel.Candidate) -> Bool {
			return lhs.id == rhs.id
		}

		// sort by reverse join date else username else id
		static func < (lhs: WhisperViewModel.Candidate, rhs: WhisperViewModel.Candidate) -> Bool {
			if let ldate = lhs.joinDate {
				if let rdate = lhs.joinDate {
					return ldate < rdate
				} else {
					return true
				}
			} else if rhs.joinDate != nil {
				return false
			} else if lhs.info.username == rhs.info.username {
				return lhs.id < rhs.id
			} else {
				return lhs.info.username < rhs.info.username
			}
		}
	}

    @Published var statusText: String = ""
    @Published var connectionError = false
    @Published var connectionErrorDescription: String = ""
	@Published var candidates: [String: Candidate] = [:]		// id -> Candidate
	@Published var listeners: [Candidate] = []
	@Published var invites: [Candidate] = []
    @Published var pastText: PastTextModel = .init(mode: .whisper)
	@Published var showStatusDetail: Bool = false
	private(set) var conversation: WhisperConversation

    private var transport: Transport
    private var cancellables: Set<AnyCancellable> = []
    private var liveText: String = ""
    private static let synthesizer = AVSpeechSynthesizer()
    private var soundEffect: AVAudioPlayer?

	let profile = UserProfile.shared.whisperProfile
	let contentId = UUID().uuidString

    init(_ conversation: WhisperConversation) {
        logger.log("Initializing WhisperView model")
		self.conversation = conversation
        self.transport = ComboFactory.shared.publisher(conversation)
        self.transport.lostRemoteSubject
            .sink { [weak self] in self?.lostRemote($0) }
            .store(in: &cancellables)
		self.transport.contentSubject
			.sink { [weak self] in self?.receiveContentChunk($0) }
			.store(in: &cancellables)
		self.transport.controlSubject
			.sink { [weak self] in self?.receiveControlChunk($0) }
			.store(in: &cancellables)
		PreferenceData.contentId = contentId
    }
    
    deinit {
        logger.log("Destroying WhisperView model")
        cancellables.cancel()
    }
    
    // MARK: View entry points
    
    func start() {
		logger.log("Starting WhisperView model")
        resetText()
        refreshStatusText()
        transport.start(failureCallback: signalConnectionError)
    }
    
    func stop() {
		logger.log("Stopping WhisperView model")
        transport.stop()
        resetText()
        refreshStatusText()
    }

	func sendRestart() {
		logger.log("Send restart message to all listeners")
		let chunk = WhisperProtocol.ProtocolChunk.restart()
		for candidate in candidates.values {
			transport.sendControl(remote: candidate.remote, chunk: chunk)
		}
	}

    /// Receive an updated live text from the view.
    /// Returns the new live text the view should display.
    func updateLiveText(old: String, new: String) -> String {
        guard old != new else {
            return liveText
        }
        let chunks = WhisperProtocol.diffLines(old: old, new: new)
        for chunk in chunks {
            if chunk.isCompleteLine() {
                pastText.addLine(liveText)
                if PreferenceData.speakWhenWhispering {
                    speak(liveText)
                }
                liveText = ""
            } else {
                liveText = WhisperProtocol.applyDiff(old: liveText, chunk: chunk)
            }
        }
        transport.publish(chunks: chunks)
        return liveText
    }
    
    /// User has submitted the live text
    func submitLiveText() -> String {
        return self.updateLiveText(old: liveText, new: liveText + "\n")
    }
    
    /// Play the alert sound to all the listeners
    func playSound() {
        let soundName = PreferenceData.alertSound
        if PreferenceData.speakWhenWhispering {
            playSoundLocally(soundName)
        }
        let chunk = WhisperProtocol.ProtocolChunk.sound(soundName)
        transport.publish(chunks: [chunk])
    }
    
    /// Send the alert sound to a specific listener
    func playSound(_ candidate: Candidate) {
        guard candidates[candidate.id] != nil else {
			logger.log("Ignoring alert request for \(candidate.remote.kind) non-candidate: \(candidate.id)")
            return
        }
        let soundName = PreferenceData.alertSound
        let chunk = WhisperProtocol.ProtocolChunk.sound(soundName)
		transport.sendContent(remote: candidate.remote, chunks: [chunk])
    }

	func acceptRequest(_ id: String) {
		guard let invitee = candidates[id] else {
			logAnomaly("Ignoring user accept of unknown candidate: \(id)")
			return
		}
		logger.info("Accepted listen request from \(invitee.remote.kind) remote \(invitee.remote.id) user \(invitee.info.username)")
		invitee.isPending = false
		refreshStatusText()
		profile.addListener(conversation, info: invitee.info)
		transport.authorize(remote: invitee.remote)
		let chunk = WhisperProtocol.ProtocolChunk.listenAuthYes(conversation, contentId: contentId)
		transport.sendControl(remote: invitee.remote, chunk: chunk)
	}

	func refuseRequest(_ id: String) {
		guard let invitee = candidates[id] else {
			logAnomaly("Ignoring user refusal of unknown candidate: \(id)")
			return
		}
		logger.info("Rejected listen request from \(invitee.remote.kind) remote \(invitee.remote.id) user \(invitee.info.username)")
		invitee.isPending = false
		refreshStatusText()
		let chunk = WhisperProtocol.ProtocolChunk.listenAuthNo(conversation)
		transport.sendControl(remote: invitee.remote, chunk: chunk)
		dropListener(invitee)
	}

    /// Drop a listener from the authorized list
    func dropListener(_ candidate: Candidate) {
        guard let listener = candidates[candidate.id] else {
			logger.log("Ignoring drop request for \(candidate.remote.kind) non-candidate: \(candidate.id)")
            return
        }
		logger.notice("De-authorizing \(listener.remote.kind) candidate \(listener.id)")
		profile.removeListener(conversation, profileId: candidate.info.profileId)
		let chunk = WhisperProtocol.ProtocolChunk.listenAuthNo(conversation)
		transport.sendControl(remote: candidate.remote, chunk: chunk)
		transport.deauthorize(remote: candidate.remote)
		candidate.joinDate = nil
		refreshStatusText()
    }

    func wentToBackground() {
        transport.goToBackground()
    }
    
    func wentToForeground() {
        transport.goToForeground()
    }
    
    // MARK: Internal helpers
    private func resetText() {
        self.pastText.clearLines()
        self.liveText = ""
    }
    
    private func signalConnectionError(_ reason: String) {
		Task { @MainActor in
			connectionError = true
			connectionErrorDescription = reason
		}
    }
    
    private func lostRemote(_ remote: Remote) {
		guard let removed = candidates.removeValue(forKey: remote.id) else {
			logger.info("Ignoring dropped \(remote.kind) non-candidate \(remote.id)")
			return
		}
		logger.info("Dropped \(remote.kind) listener \(removed.id)")
        refreshStatusText()
    }

	private func receiveContentChunk(_ pair: (remote: Remote, chunk: WhisperProtocol.ProtocolChunk)) {
		fatalError("Whisperer received content (\(pair.chunk.toString())) from \(pair.remote.id)")
	}

	private func receiveControlChunk(_ pair: (remote: Remote, chunk: WhisperProtocol.ProtocolChunk)) {
		processControlChunk(remote: pair.remote, chunk: pair.chunk)
	}

	private func processControlChunk(remote: Remote, chunk: WhisperProtocol.ProtocolChunk) {
		if chunk.isPresenceMessage() {
			guard let info = WhisperProtocol.ClientInfo.fromString(chunk.text) else {
				fatalError("Received a presence message with invalid data: \(chunk.toString())")
			}
			guard info.conversationId == conversation.id else {
				logger.info("Ignoring a presence message about the wrong conversation: \(info.conversationId)")
				return
			}
			let offset = WhisperProtocol.ControlOffset(rawValue: chunk.offset)
			switch offset {
			case .listenOffer, .listenRequest:
				let candidate = candidateFor(remote: remote, info: info)
				if candidate.isPending {
					if offset == .listenOffer {
						logger.info("Sending whisper offer to new \(remote.kind) listener: \(candidate.id)")
						let chunk = WhisperProtocol.ProtocolChunk.whisperOffer(conversation)
						transport.sendControl(remote: candidate.remote, chunk: chunk)
					} else {
						logger.info("Making invite for new \(remote.kind) listener: \(candidate.id)")
						refreshStatusText()
					}
				} else {
					logger.info("Authorizing known \(remote.kind) listener: \(candidate.id)")
					transport.authorize(remote: candidate.remote)
					let chunk = WhisperProtocol.ProtocolChunk.listenAuthYes(conversation, contentId: contentId)
					transport.sendControl(remote: candidate.remote, chunk: chunk)
				}
			case .joining:
				let candidate = candidateFor(remote: remote, info: info)
				logger.info("\(remote.kind) Listener has joined the conversation: \(candidate.id)")
				candidate.joinDate = Date.now
				refreshStatusText()
				showStatusDetail = true
			default:
				fatalError("\(remote.kind) Listener sent an unexpected presence message: \(chunk)")
			}
		} else if chunk.isReplayRequest() {
			guard let candidate = candidates[remote.id], !candidate.isPending else {
				logger.warning("Ignoring replay request from \(remote.kind) unknown/unauthorized remote \(remote.id)")
				return
			}
			let chunks = [WhisperProtocol.ProtocolChunk.fromLiveText(text: liveText)]
			transport.sendContent(remote: candidate.remote, chunks: chunks)
		}
	}

	private func candidateFor(
		remote: Remote,
		info: WhisperProtocol.ClientInfo
	) -> Candidate {
		var authorized = profile.isListener(conversation, info: info)
		// if my profile is shared, I am always an authorized listener for my own conversations
		if (!UserProfile.shared.userPassword.isEmpty && info.profileId == UserProfile.shared.id) {
			authorized = ListenerInfo(id: UserProfile.shared.id, username: UserProfile.shared.username)
		}
		let candidate = candidates[remote.id] ?? Candidate(remote: remote, info: info, isPending: authorized == nil)
		candidates[candidate.id] = candidate
		if !info.username.isEmpty {
			// always use the latest username we are sent (see #59)
			candidate.info.username = info.username
			if authorized != nil {
				// this is a known listener, also update their name in our profile
				profile.addListener(conversation, info: info)
			}
		} else if candidate.info.username.isEmpty, let auth = authorized {
			candidate.info.username = auth.username
		}
		return candidate
	}

	private func speak(_ text: String) {
		if PreferenceData.elevenLabsApiKey().isEmpty || PreferenceData.elevenLabsVoiceId().isEmpty {
			let utterance = AVSpeechUtterance(string: text)
			Self.synthesizer.speak(utterance)
		} else {
			ElevenLabs.shared.speakText(text: text)
		}
	}
    
    // play the alert sound locally
    private func playSoundLocally(_ name: String) {
        var name = name
        var path = Bundle.main.path(forResource: name, ofType: "caf")
        if path == nil {
            // try again with default sound
            name = PreferenceData.alertSound
            path = Bundle.main.path(forResource: name, ofType: "caf")
        }
        guard path != nil else {
            logger.error("Couldn't find sound file for '\(name, privacy: .public)'")
            return
        }
        let url = URL(fileURLWithPath: path!)
        soundEffect = try? AVAudioPlayer(contentsOf: url)
        if let player = soundEffect {
            if !player.play() {
                logger.error("Couldn't play sound '\(name, privacy: .public)'")
            }
        } else {
            logger.error("Couldn't create player for sound '\(name, privacy: .public)'")
        }
    }

    private func refreshStatusText() {
		listeners = candidates.values.filter{$0.joinDate != nil}.sorted()
		invites = candidates.values.filter{$0.isPending}.sorted()
		if listeners.isEmpty {
			if invites.isEmpty {
				statusText = "\(conversation.name): No listeners yet, but you can type"
			} else {
				statusText = "\(conversation.name): Tap to see pending listeners"
			}
		} else if listeners.count == 1 {
			if invites.isEmpty {
				statusText = "\(conversation.name): Whispering to \(listeners.first!.info.username)"
			} else {
				statusText = "\(conversation.name): Whispering to \(listeners.first!.info.username) (+ \(invites.count) pending)"
			}
        } else {
			if invites.isEmpty {
				statusText = "\(conversation.name): Whispering to \(listeners.count) listeners"
			} else {
				statusText = "\(conversation.name): Whispering to \(listeners.count) listeners (+ \(invites.count) pending)"
			}
        }
		if !invites.isEmpty {
			showStatusDetail = true
		} else if listeners.isEmpty {
			showStatusDetail = false
		}
    }
}
