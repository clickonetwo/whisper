// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Foundation
import Combine
import Ably

final class TcpListenTransport: SubscribeTransport {
    // MARK: Protocol properties and methods
    typealias Remote = Whisperer
    
    var lostRemoteSubject: PassthroughSubject<Remote, Never> = .init()
	var contentSubject: PassthroughSubject<(remote: Remote, chunk: WhisperProtocol.ProtocolChunk), Never> = .init()
	var controlSubject: PassthroughSubject<(remote: Remote, chunk: WhisperProtocol.ProtocolChunk), Never> = .init()

    func start(failureCallback: @escaping (String) -> Void) {
        logger.log("Starting TCP listen transport")
        self.failureCallback = failureCallback
		self.authenticator = TcpAuthenticator(mode: .listen,
											  conversationId: conversation.id,
											  conversationName: conversation.name,
											  callback: receiveAuthError)
        openControlChannel()
    }
    
    func stop() {
        logger.info("Stopping TCP listen transport")
        closeChannels()
    }
    
    func goToBackground() {
    }
    
    func goToForeground() {
    }
    
    func sendControl(remote: Remote, chunk: WhisperProtocol.ProtocolChunk) {
        guard let target = remotes[remote.id] else {
            logger.error("Ignoring request to send chunk to an unknown \(remote.kind, privacy: .public) remote: \(remote.id, privacy: .public)")
            return
        }
		logger.notice("Sending control packet to \(remote.kind) remote: \(remote.id, privacy: .public): \(chunk, privacy: .public)")
		sendControlInternal(id: target.id, data: chunk.toString())
    }
    
    func drop(remote: Remote) {
        guard remotes[remote.id] != nil else {
            fatalError("Ignoring request to drop an unknown remote: \(remote.id)")
        }
		removeCandidate(remote, sendDrop: true)
    }
    
	func subscribe(remote: Remote, conversation: ListenConversation) {
        guard let remote = remotes[remote.id] else {
            logger.error("Ignoring request to subscribe to an unknown \(remote.kind, privacy: .public) remote: \(remote.id, privacy: .public)")
            return
        }
		if whisperer === remote {
			logger.error("Ignoring duplicate subscribe")
			return
		} else if let w = whisperer {
			fatalError("Got subscribe request to \(remote.id) but already subscribed to \(w.id)")
		}
		guard self.conversation == conversation else {
			fatalError("Can't subscribe to \(conversation.id): initialized with \(self.conversation.id)")
		}
        whisperer = remote
		openContentChannel(remote: remote)
		for remote in Array(remotes.values) {
			if remote !== whisperer {
				drop(remote: remote)
			}
		}
    }
    
    // MARK: Internal types, properties, and initialization
    final class Whisperer: TransportRemote {
        let id: String
		let kind: TransportKind = .global

		fileprivate var contentId = ""
		fileprivate var lastControlPacketOffset: Int = 0

        fileprivate init(id: String) {
            self.id = id
        }
    }
    
    private var failureCallback: ((String) -> Void)?
    private var clientId: String
    private var conversation: ListenConversation
    private var authenticator: TcpAuthenticator!
    private var client: ARTRealtime?
    private var channelName: String
    private var contentChannel: ARTRealtimeChannel?
    private var controlChannel: ARTRealtimeChannel?
	private var controlQueue: [(id: String, data: String)] = []
    private var remotes: [String:Remote] = [:]
    private var whisperer: Remote?

    init(_ conversation: ListenConversation?) {
		guard let conversation = conversation else {
			fatalError("Can't listen over the network without a conversation")
		}
        self.clientId = PreferenceData.clientId
        self.conversation = conversation
		self.channelName = conversation.id
    }
    
    //MARK: Internal methods
    private func receiveErrorInfo(_ error: ARTErrorInfo?) {
        if let error = error {
			logger.error("TCP Listener: \(error.message, privacy: .public)")
        }
    }
    
    private func receiveAuthError(_ reason: String) {
        failureCallback?(reason)
        closeChannels()
    }
    
    private func getClient() -> ARTRealtime {
        if let client = self.client {
            return client
        }
        let client = self.authenticator.getClient()
        client.connection.on(.connected) { _ in
            logger.log("TCP listen transport realtime client has connected")
        }
        client.connection.on(.disconnected) { _ in
            logger.log("TCP listen transport realtime client has disconnected")
        }
        return client
    }
    
	private func openContentChannel(remote: Remote) {
		guard !remote.contentId.isEmpty else {
			fatalError("Can't subscribe to remote with no content ID: \(remote)")
		}
		contentChannel = getClient().channels.get(channelName + ":" + remote.contentId)
        contentChannel?.on(.attached) { stateChange in
            logger.log("TCP listen transport realtime client has attached the content channel")
        }
        contentChannel?.on(.detached) { stateChange in
            logger.log("TCP listen transport realtime client has detached the content channel")
        }
        contentChannel?.attach()
        contentChannel?.subscribe(clientId, callback: receiveContentMessage)
        contentChannel?.subscribe("all", callback: receiveContentMessage)
    }
    
    private func openControlChannel() {
		logger.info("TCP listen transport: open control channel")
        controlChannel = getClient().channels.get(channelName + ":control")
        controlChannel?.on(.attached) { stateChange in
			logger.info("TCP listen transport: attach to control channel")
        }
        controlChannel?.on(.detached) { stateChange in
            logger.log("TCP listen transport: detach from control channel")
        }
        controlChannel?.attach()
        controlChannel?.subscribe(clientId, callback: receiveControlMessage)
        controlChannel?.subscribe("all", callback: receiveControlMessage)
		// send a listen offer so the whisperer knows we're here
		let chunk = WhisperProtocol.ProtocolChunk.listenOffer(conversation)
		logger.info("TCP listen transport: sending listen offer: \(chunk)")
		sendControlInternal(id: "whisperer", data: chunk.toString())
    }
    
    private func closeChannels() {
		guard let control = controlChannel else {
			// we never opened the channels, so don't try to close them
			return
		}
		logger.info("TCP listen transport: closing both channels")
		logger.info("TCP listen transport: publishing drop to \(self.remotes.count) remotes")
		let chunk = WhisperProtocol.ProtocolChunk.dropping()
        control.publish("whisperer", data: chunk.toString(), callback: receiveErrorInfo)
		if let content = contentChannel {
			content.detach()
			contentChannel = nil
		}
        control.detach()
        controlChannel = nil
		client = nil
		authenticator.releaseClient()
    }

	private func sendControlInternal(id: String, data: String) {
		// we may send control packets more than once to make sure one gets through
		// Because we don't want to interleave packets of different types, we keep a queue of the ones to send
		let suffix = controlChannelPacketRepeatCount > 1 ? " \(controlChannelPacketRepeatCount) times" : ""
		if controlQueue.isEmpty {
			logger.debug("TCP whisper transport: sending control packet\(suffix)")
			controlChannel?.publish(id, data: data, callback: receiveErrorInfo)
			if controlChannelPacketRepeatCount > 1 {
				var current = (id: id, data: data)
				controlQueue.append(current)
				var count = 1
				Timer.scheduledTimer(withTimeInterval: TimeInterval(0.05), repeats: true) { [weak self] timer in
					guard self != nil else {
						timer.invalidate()
						return
					}
					if count >= controlChannelPacketRepeatCount {
						self?.controlQueue.removeFirst()
						if let next = self?.controlQueue.first {
							logger.debug("TCP whisper transport: dequeing control packet")
							current = next
							count = 0
						} else {
							timer.invalidate()
							return
						}
					}
					self?.controlChannel?.publish(current.id, data: current.data, callback: self?.receiveErrorInfo)
					count += 1
				}
			}
		} else {
			logger.debug("TCP whisper transport: queueing control packet")
			controlQueue.append((id: id, data: data))
		}
	}

	private func removeCandidate(_ remote: Remote, sendDrop: Bool = false) {
		logger.log("Removing \(remote.kind) remote \(remote.id)")
		remotes.removeValue(forKey: remote.id)
		if sendDrop {
				let chunk = WhisperProtocol.ProtocolChunk.dropping()
				sendControl(remote: remote, chunk: chunk)
		}
	}

	func receiveContentMessage(message: ARTMessage) {
		guard let remote = remoteFor(message.clientId) else {
			logger.error("Ignoring a message with a missing client id: \(message, privacy: .public)")
			return
		}
		guard let payload = message.data as? String,
			  let chunk = WhisperProtocol.ProtocolChunk.fromString(payload) else {
			logger.error("Ignoring a message with a non-chunk payload: \(message, privacy: .public)")
			return
		}
		contentSubject.send((remote: remote, chunk: chunk))
	}

    func receiveControlMessage(message: ARTMessage) {
		guard let remote = remoteFor(message.clientId) else {
			logger.error("Ignoring a message with a missing client id: \(message, privacy: .public)")
			return
		}
        guard let payload = message.data as? String,
              let chunk = WhisperProtocol.ProtocolChunk.fromString(payload) else {
			logger.error("Ignoring a message with a non-chunk payload: \(message, privacy: .public)")
            return
        }
		guard chunk.offset != remote.lastControlPacketOffset else {
			logger.notice("Ignoring repeated packet: \(chunk, privacy: .public)")
			return
		}
		remote.lastControlPacketOffset = chunk.offset
        if chunk.isPresenceMessage() {
            guard let info = WhisperProtocol.ClientInfo.fromString(chunk.text),
                  info.clientId == message.clientId
            else {
				logger.error("Ignoring a malformed or misdirected packet: \(chunk, privacy: .public)")
                return
            }
            if let value = WhisperProtocol.ControlOffset(rawValue: chunk.offset) {
                switch value {
				case .dropping:
					logger.info("Advised of drop from \(remote.kind) remote \(remote.id)")
					removeCandidate(remote)
					lostRemoteSubject.send(remote)
					// no more processing to do on this packet
					return
                case .listenAuthYes:
					logger.info("Capturing content id from \(remote.kind) remote \(remote.id)")
					let contentId = info.contentId
					guard !contentId.isEmpty else {
						fatalError("Received an empty content id in a TCP \(value) message")
					}
					remote.contentId = contentId
                default:
					break
                }
            }
        }
		logger.notice("Received control packet from \(remote.kind, privacy: .public) remote \(remote.id, privacy: .public): \(chunk, privacy: .public)")
		logger.info("Received control packet: \(chunk)")
        controlSubject.send((remote: remote, chunk: chunk))
    }

	private func remoteFor(_ clientId: String?) -> Remote? {
		guard let clientId = clientId else {
			return nil
		}
		if let existing = remotes[clientId] {
			return existing
		}
		let remote = Whisperer(id: clientId)
		remotes[clientId] = remote
		return remote
	}
}
