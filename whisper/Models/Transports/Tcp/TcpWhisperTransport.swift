// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import Foundation
import Combine

final class TcpWhisperTransport: PublishTransport {
    // MARK: protocol properties and methods
    typealias Remote = Listener
    
    var addRemoteSubject: PassthroughSubject<Remote, Never> = .init()
    var dropRemoteSubject: PassthroughSubject<Remote, Never> = .init()
    var receivedChunkSubject: PassthroughSubject<(remote: Remote, chunk: TextProtocol.ProtocolChunk), Never> = .init()
    
    func start() -> Bool {
        logger.log("Starting TCP whisper transport")
        guard let tokenRequest = getTokenRequest(mode: .whisper, publisherId: PreferenceData.clientId) else {
            logger.error("Couldn't obtain token for publishing")
            return false
        }
        self.tokenRequest = tokenRequest
        return true
    }
    
    func stop() {
        logger.log("Stopping TCP whisper Transport")
    }
    
    func goToBackground() {
    }
    
    func goToForeground() {
    }
    
    func send(remote: Listener, chunks: [TextProtocol.ProtocolChunk]) {
        fatalError("'send' not yet implemented")
    }
    
    func drop(remote: Listener) {
        fatalError("'drop' not yet implemented")
    }
    
    func publish(chunks: [TextProtocol.ProtocolChunk]) {
        fatalError("'publish' not yet implemented")
    }
    
    // MARK: Internal types, properties, and initialization
    final class Listener: TransportRemote {
        let id: String
        var name: String
        
        init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }
    
    private var tokenRequest: String?

    init() {
    }
    
    //MARK: Internal methods
}
