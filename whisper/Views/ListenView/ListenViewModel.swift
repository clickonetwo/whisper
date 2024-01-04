// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import AVFAudio
import Combine
import CoreBluetooth
import UserNotifications

final class ListenViewModel: ObservableObject {
    typealias Remote = ComboFactory.Subscriber.Remote
    typealias Transport = ComboFactory.Subscriber

	final class Candidate: Identifiable, Comparable {
		private(set) var id: String
		private(set) var remote: Remote
		private(set) var info: WhisperProtocol.ClientInfo
		var isPending: Bool
		private(set) var created: Date

		init(remote: Remote, info: WhisperProtocol.ClientInfo, isPending: Bool) {
			self.id = remote.id
			self.remote = remote
			self.isPending = isPending
			self.created = Date.now
		}

		// compare by network and creation date
		static func == (lhs: ListenViewModel.Candidate, rhs: ListenViewModel.Candidate) -> Bool {
			return lhs.remote.kind == rhs.remote.kind && lhs.created == rhs.created
		}

		// sort by network, then oldest first
		static func < (lhs: ListenViewModel.Candidate, rhs: ListenViewModel.Candidate) -> Bool {
			if lhs.remote.kind == rhs.remote.kind {
				return lhs.created > rhs.created
			} else {
				return lhs.remote.kind == .local
			}
		}
	}

    @Published var statusText: String = ""
    @Published var liveText: String = ""
    @Published var connectionError: Bool = false
    @Published var conversationEnded: Bool = false
    @Published var connectionErrorDescription: String = "The connection to the whisperer was lost"
    @Published var showStatusDetail: Bool = false
	@Published var candidates: [String: Candidate] = [:]	// remoteId -> Candidate
	@Published var invites: [Candidate] = []
	@Published var conversation: Conversation?
    @Published var whisperer: Candidate?
    @Published var pastText: PastTextModel = .init(mode: .listen)

    private var transport: Transport
    private var cancellables: Set<AnyCancellable> = []
	private var clients: [String: Candidate] = [:]	// clientId -> Candidate, for avoiding dups
    private var discoveryInProgress = false
    private var discoveryCountDown = 0
    private var discoveryTimer: Timer?
    private var resetInProgress = false
    private var isFirstConnect = true
    private var isInBackground = false
    private var soundEffect: AVAudioPlayer?
    private var notifySoundInBackground = false
    private static let synthesizer = AVSpeechSynthesizer()

	let profile = UserProfile.shared

    init(_ conversation: Conversation?) {
        logger.log("Initializing ListenView model")
		self.conversation = conversation
        transport = ComboFactory.shared.subscriber(conversation)
        transport.lostRemoteSubject
            .sink{ [weak self] in self?.dropCandidate($0) }
            .store(in: &cancellables)
		transport.contentSubject
			.sink{ [weak self] in self?.receiveContentChunk($0) }
			.store(in: &cancellables)
		transport.controlSubject
			.sink{ [weak self] in self?.receiveControlChunk($0) }
			.store(in: &cancellables)
    }
    
    deinit {
        cancellables.cancel()
    }
    
    // MARK: View entry points
    func start() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if error != nil {
                logger.error("Error asking the user to approve alerts: \(error!)")
            }
            self.notifySoundInBackground = granted
        }
        resetTextForConnection()
		awaitDiscovery()
        refreshStatusText()
        transport.start(failureCallback: signalConnectionError)
    }
    
    func stop() {
        cancelDiscovery()
        transport.stop()
        statusText = "Stopped Listening"
    }
    
    func wentToBackground() {
        guard !isInBackground else {
            return
        }
        isInBackground = true
        transport.goToBackground()
    }
    
    func wentToForeground() {
        guard isInBackground else {
            return
        }
        isInBackground = false
        transport.goToForeground()
        // after going to background, assume not waiting any more
        logger.log("End initial wait for whisperers due to background transition")
        cancelDiscovery()
    }

	func acceptInvite(_ id: String) {
		guard let candidate = candidates[id] else {
			fatalError("Can't accept a non-invite: \(id)")
		}
		candidate.isPending = false
		invites = candidates.values.filter{$0.isPending}.sorted()
	}

	func refuseInvite(_ id: String) {
		guard let candidate = candidates.removeValue(forKey: id) else {
			fatalError("Can't reject a non-invite: \(id)")
		}
		clients.removeValue(forKey: candidate.info.clientId)
		transport.drop(remote: candidate.remote)
		invites = candidates.values.filter{$0.isPending}.sorted()
	}

    // re-read the whispered text
    func readLiveText() {
        guard let whisperer = whisperer else {
			fatalError("Can't read live text with no Whisperer")
        }
        guard !resetInProgress else {
            logger.log("Got reset during reset, ignoring it")
            return
        }
        logger.log("Requesting re-read of live text")
        resetInProgress = true
        let chunk = WhisperProtocol.ProtocolChunk.replayRequest(hint: WhisperProtocol.ReadType.live)
		transport.sendControl(remote: whisperer.remote, chunk: chunk)
    }
    
    // MARK: Transport subscription handlers
    private func dropCandidate(_ remote: Remote) {
		guard let removed = candidates.removeValue(forKey: remote.id) else {
            logger.error("Ignoring dropped non-candidate \(remote.id)")
            return
        }
		clients.removeValue(forKey: removed.info.clientId)
        if removed === whisperer {
            logger.info("Dropped the whisperer \(removed.id)")
            whisperer = nil
            // we have lost the whisperer, stop listening
            resetTextForConnection()
            refreshStatusText()
            conversationEnded = true
        } else {
            logger.info("Dropped candidate \(removed.id)")
        }
    }
    
    private func receiveContentChunk(_ pair: (remote: Remote, chunk: WhisperProtocol.ProtocolChunk)) {
		guard pair.remote.id == whisperer?.id else {
            fatalError("Received content from non-whisperer \(pair.remote.id)")
        }
        processContentChunk(pair.chunk)
    }
        
	private func receiveControlChunk(_ pair: (remote: Remote, chunk: WhisperProtocol.ProtocolChunk)) {
		guard whisperer == nil else {
			// we shouldn't be seeing control messages from an active whisperer
			fatalError("Received a control message while listening: \(pair)")
		}
		processControlChunk(remote: pair.remote, chunk: pair.chunk)
	}

    // MARK: internal helpers
    private func resetTextForConnection() {
        if isFirstConnect {
            liveText = connectingLiveText
            pastText.setFromText(connectingPastText)
        } else {
            self.liveText = connectingLiveText
        }
    }
    
    private func signalConnectionError(_ reason: String) {
        Task { @MainActor in
            connectionError = true
            connectionErrorDescription = reason
        }
    }
    
    private func processContentChunk(_ chunk: WhisperProtocol.ProtocolChunk) {
        if chunk.isSound() {
            logger.log("Received request to play sound '\(chunk.text)'")
            playSound(chunk.text)
        } else if resetInProgress {
            if chunk.isFirstRead() {
                logger.log("Received reset acknowledgement from whisperer")
            } else if chunk.isDiff() {
                logger.log("Ignoring diff chunk because a read is in progress")
            } else if chunk.isCompleteLine() {
                logger.debug("Got past line \(self.pastText.pastText.count) in read")
                pastText.addLine(chunk.text)
            } else if chunk.isLastRead() {
                logger.log("Reset completes with \(chunk.text.count) live characters")
                liveText = chunk.text
                resetInProgress = false
            }
        } else {
            if !chunk.isDiff() {
                logger.log("Ignoring non-diff chunk because no read in progress")
            } else if chunk.offset == 0 {
//                logger.debug("Got diff: live text is '\(chunk.text)'")
                liveText = chunk.text
            } else if chunk.isCompleteLine() {
//				logger.log("Got diff: move live text to past text")
                if !isInBackground && PreferenceData.speakWhenListening {
                    speak(liveText)
                }
                pastText.addLine(liveText)
                liveText = ""
            } else if chunk.offset > liveText.count {
                // we must have missed a packet, read the full state to reset
                PreferenceData.droppedErrorCount += 1
                logger.log("Resetting live text after missed packet...")
                readLiveText()
            } else {
//                logger.debug("Got diff: live text[\(chunk.offset)...] updated to '\(chunk.text)'")
                liveText = WhisperProtocol.applyDiff(old: liveText, chunk: chunk)
            }
        }
    }

	private func processControlChunk(remote: Remote, chunk: WhisperProtocol.ProtocolChunk) {
		guard chunk.isPresenceMessage() else {
			fatalError("Listener received a non-presence message: \(chunk)")
		}
		guard let info = WhisperProtocol.ClientInfo.fromString(chunk.text) else {
			fatalError("Listener received a presence message with invalid data: \(chunk)")
		}
		switch WhisperProtocol.ControlOffset(rawValue: chunk.offset) {
		case .whisperOffer:
			let conversation = profile.listenConversationForInvite(info: info)
			if let candidate = candidateFor(remote: remote, info: info, conversation: conversation) {
				if candidate.isPending {
					invites = candidates.values.filter{$0.isPending}.sorted()
					showStatusDetail = true
				}
			}
		case .listenAuthYes:
			let conversation = profile.addListenConversationForInvite(info: info)
			if let candidate = candidateFor(remote: remote, info: info, conversation: conversation) {
				setWhisperer(candidate: candidate, conversation: conversation)
			}
		default:
			fatalError("Listener received an unexpected presence message: \(chunk)")
		}
	}

	private func candidateFor(
		remote: Remote,
		info: WhisperProtocol.ClientInfo, 
		conversation: Conversation
	) -> Candidate? {
		if let existing = candidates[remote.id] {
			return existing
		}
		guard clients[info.clientId] == nil else {
			logger.info("Ignoring second appearance of client via different network: \(remote.kind)")
			return nil
		}
		let candidate = Candidate(remote: remote, info: info, isPending: conversation.lastListened == Date.distantPast)
		candidates[candidate.id] = candidate
		clients[candidate.info.clientId] = candidate
		return candidate
	}

    private func playSound(_ name: String) {
        var name = name
        var path = Bundle.main.path(forResource: name, ofType: "caf")
        if path == nil {
            // try again with default sound
            name = PreferenceData.alertSound
            path = Bundle.main.path(forResource: name, ofType: "caf")
        }
        guard path != nil else {
            logger.error("Couldn't find sound file for '\(name)'")
            return
        }
        guard !isInBackground else {
            notifySound(name)
            return
        }
        let url = URL(fileURLWithPath: path!)
        soundEffect = try? AVAudioPlayer(contentsOf: url)
        if let player = soundEffect {
            if !player.play() {
                logger.error("Couldn't play sound '\(name)'")
            }
        } else {
            logger.error("Couldn't create player for sound '\(name)'")
        }
    }
    
    private func notifySound(_ name: String) {
        guard notifySoundInBackground else {
            logger.error("Received background request to play sound '\(name)' but don't have permission.")
            return
        }
        let soundName = UNNotificationSoundName(name + ".caf")
        let sound = UNNotificationSound(named: soundName)
        let content = UNMutableNotificationContent()
        content.title = "Whisper"
        content.body = "The whisperer wants your attention!"
        content.sound = sound
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.25, repeats: false)
        let uuid = UUID().uuidString
        let request = UNNotificationRequest(identifier: uuid, content: content, trigger: trigger)
        let center = UNUserNotificationCenter.current()
        center.add(request) { error in if error != nil { logger.error("Couldn't notify: \(error!)") } }
    }
    
    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        Self.synthesizer.speak(utterance)
    }
    
    /// Wait for a while so discovery can find multiple listeners
    private func awaitDiscovery() {
        guard !isInBackground else {
            fatalError("Can't start the listener scan in the background")
        }
        logger.log("Start initial wait for whisperers")
        discoveryInProgress = true
        discoveryCountDown = Int(listenerWaitTime + 1)
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(1), repeats: true) { timer in
            guard self.discoveryInProgress && self.discoveryCountDown > 0 else {
                logger.log("End initial wait for whisperers due to timeout")
                timer.invalidate()
                self.discoveryTimer = nil
                self.discoveryCountDown = 0
                self.discoveryInProgress = false
                self.refreshStatusText()
                return
            }
            self.discoveryCountDown -= 1
            self.refreshStatusText()
        }
    }
    
    /// Cancel the wait for discovery
    private func cancelDiscovery() {
        guard let timer = discoveryTimer else {
            return
        }
		logger.log("End initial wait for whisperers explicitly")
        timer.invalidate()
        discoveryTimer = nil
        discoveryInProgress = false
    }
    
	/// subscribe to this candidate
	func setWhisperer(candidate: Candidate, conversation: Conversation) {
		guard whisperer == nil else {
			fatalError("Ignoring attempt to set whisperer when we already have one")
		}
		logger.info("Selecting whisperer \(candidate.id) for conversation \(conversation.id)")
		whisperer = candidate
		// refresh status text
		cancelDiscovery()
		refreshStatusText()
		// drop other candidates and invites
		candidates = [candidate.id: candidate]
		invites = []
		// tell the transport we're subscribing
		transport.subscribe(remote: candidate.remote, conversation: conversation)
		// update the view
		refreshStatusText()
		if isFirstConnect {
			isFirstConnect = false
			pastText.clearLines()
		}
		liveText = ""
		// catch up
		readLiveText()
	}

	private func refreshStatusText() {
        if let whisperer = whisperer {
			statusText = "Listening to \(whisperer.info.username)"
        } else if discoveryInProgress {
            let suffix = discoveryCountDown > 0 ? " \(discoveryCountDown)" : ""
            statusText = "Looking for whisperers…\(suffix)"
        } else {
            statusText = "Waiting for a whisperer to appear…"
        }
    }
}
