import Foundation
import Discovery

/// テスト用モックトランスポート
final class MockTransport: Transport, @unchecked Sendable {
    let transportID: String
    let displayName: String

    private let state = MockTransportState()

    init(transportID: String = "mock", displayName: String = "Mock Transport") {
        self.transportID = transportID
        self.displayName = displayName
    }

    // MARK: - テストヘルパー

    var startCount: Int {
        get async { await state.startCount }
    }

    var stopCount: Int {
        get async { await state.stopCount }
    }

    var isActive: Bool {
        get async { await state.isActive }
    }

    func addDiscoveredPeer(_ peerID: PeerID) async {
        await state.addDiscoveredPeer(peerID)
    }

    func addResolvedPeer(_ peer: ResolvedPeer) async {
        await state.addResolvedPeer(peer)
    }

    func setSendResult(_ result: Data) async {
        await state.setSendResult(result)
    }

    // MARK: - Transport Protocol

    func start() async throws {
        await state.start()
    }

    func stop() async throws {
        await state.stop()
    }

    var events: AsyncStream<TransportEvent> {
        get async {
            AsyncStream { continuation in
                Task {
                    await state.setEventContinuation(continuation)
                }
            }
        }
    }

    func resolve(_ peerID: PeerID) async throws -> ResolvedPeer? {
        await state.resolve(peerID)
    }

    func discover(timeout: Duration) -> AsyncThrowingStream<PeerID, Error> {
        AsyncThrowingStream { [state] continuation in
            Task {
                for peerID in await state.discoveredPeers {
                    continuation.yield(peerID)
                }
                continuation.finish()
            }
        }
    }

    func send(to peerID: PeerID, data: Data, timeout: Duration) async throws -> Data {
        guard await state.isActive else {
            throw Discovery.TransportError.notStarted
        }
        return await state.sendResult ?? Data()
    }
}

/// スレッドセーフな状態管理
actor MockTransportState {
    var isActive: Bool = false
    var startCount: Int = 0
    var stopCount: Int = 0
    var discoveredPeers: [PeerID] = []
    var resolvedPeers: [PeerID: ResolvedPeer] = [:]
    var sendResult: Data?
    var eventContinuation: AsyncStream<TransportEvent>.Continuation?

    func start() {
        isActive = true
        startCount += 1
    }

    func stop() {
        isActive = false
        stopCount += 1
    }

    func addDiscoveredPeer(_ peerID: PeerID) {
        discoveredPeers.append(peerID)
    }

    func addResolvedPeer(_ peer: ResolvedPeer) {
        resolvedPeers[peer.peerID] = peer
    }

    func resolve(_ peerID: PeerID) -> ResolvedPeer? {
        resolvedPeers[peerID]
    }

    func setSendResult(_ result: Data) {
        sendResult = result
    }

    func setEventContinuation(_ continuation: AsyncStream<TransportEvent>.Continuation) {
        eventContinuation = continuation
    }
}
