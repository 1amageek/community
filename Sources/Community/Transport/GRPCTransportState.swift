import Foundation
import Discovery
import Synchronization

/// Thread-safe state management for GRPCTransport using Mutex.
final class GRPCTransportState: Sendable {
    // MARK: - Internal State

    private struct State: Sendable {
        var isActive: Bool = false
        var registeredPeers: [Discovery.PeerID: ProtoPeerInfo] = [:]
        var resolvedPeers: [Discovery.PeerID: Discovery.ResolvedPeer] = [:]
        var eventContinuation: AsyncStream<Discovery.TransportEvent>.Continuation?
    }

    private let state = Mutex(State())

    // MARK: - Properties

    var isActive: Bool {
        state.withLock { $0.isActive }
    }

    // MARK: - Lifecycle

    func start() {
        state.withLock { $0.isActive = true }
    }

    func stop() {
        state.withLock { state in
            state.isActive = false
            state.eventContinuation?.finish()
            state.eventContinuation = nil
            state.registeredPeers.removeAll()
            state.resolvedPeers.removeAll()
        }
    }

    // MARK: - Event Handling

    func setEventContinuation(_ continuation: AsyncStream<Discovery.TransportEvent>.Continuation) {
        state.withLock { $0.eventContinuation = continuation }
    }

    func emitEvent(_ event: Discovery.TransportEvent) {
        state.withLock { $0.eventContinuation?.yield(event) }
    }

    // MARK: - Peer Registration

    func registerPeer(_ peer: ProtoPeerInfo) {
        let peerID = Discovery.PeerID(peer.peerID)
        state.withLock { $0.registeredPeers[peerID] = peer }
        emitEvent(.peerDiscovered(peerID))
    }

    func unregisterPeer(_ peerID: Discovery.PeerID) {
        state.withLock { $0.registeredPeers.removeValue(forKey: peerID) }
        emitEvent(.peerLost(peerID))
    }

    func getRegisteredPeer(_ peerID: Discovery.PeerID) -> ProtoPeerInfo? {
        state.withLock { $0.registeredPeers[peerID] }
    }

    // MARK: - Discovery

    /// Returns all registered peer IDs
    func allPeerIDs() -> [Discovery.PeerID] {
        state.withLock { Array($0.registeredPeers.keys) }
    }

    // MARK: - Resolution Cache

    func cacheResolvedPeer(_ peer: Discovery.ResolvedPeer) {
        state.withLock { $0.resolvedPeers[peer.peerID] = peer }
    }

    func getCachedResolvedPeer(_ peerID: Discovery.PeerID) -> Discovery.ResolvedPeer? {
        state.withLock { state in
            guard let peer = state.resolvedPeers[peerID], peer.isValid else {
                state.resolvedPeers.removeValue(forKey: peerID)
                return nil
            }
            return peer
        }
    }

    func clearResolvedPeerCache() {
        state.withLock { $0.resolvedPeers.removeAll() }
    }
}
