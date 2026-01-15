import Foundation
import PeerNode

// MARK: - Peer Management

extension CommunitySystem {
    /// Connect to a peer
    public func connectToPeer(_ peerID: PeerID) async throws {
        try await node.connect(to: peerID)

        // Start processing messages from this peer
        guard let transport = node.transport(for: peerID) else {
            return
        }

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.processMessages(from: transport, peerID: peerID)
        }

        state.withLock { s in
            s.messageTasks.append(task)
        }

        // Exchange member information with the connected peer
        await exchangeMemberInfo(with: peerID)
    }

    /// Exchange member information with a connected peer
    func exchangeMemberInfo(with peerID: PeerID) async {
        do {
            let remoteSystemActor = try remoteSystemActor(peerID: peerID)
            let remoteMembers = try await remoteSystemActor.listMembers()

            // Store remote members (skip our own members)
            state.withLock { s in
                for member in remoteMembers {
                    // Don't store our own members
                    if member.peerID != localPeerInfo.peerID {
                        s.remoteMembers[member.actorID.id] = member
                    }
                }
            }
        } catch {
            // Failed to exchange member info - not critical
        }
    }

    /// Get all connected peer IDs
    public func connectedPeers() -> [PeerID] {
        node.connectedPeers
    }

    /// Disconnect from a specific peer
    public func disconnectPeer(_ peerID: PeerID) async {
        // Disconnect from the peer
        await node.disconnect(from: peerID)

        // Clean up remote members from this peer
        cleanupDisconnectedPeer(peerID)
    }
}

// MARK: - Connection Handling

extension CommunitySystem {
    func acceptConnections() async {
        for await connection in node.incomingConnections {
            let peerID = connection.peerID

            // Start processing messages from this connection
            let task: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.processMessages(from: connection.transport, peerID: peerID)
            }

            state.withLock { s in
                s.messageTasks.append(task)
            }

            // Exchange member information with the connected peer
            Task { [weak self] in
                guard let self else { return }
                await self.exchangeMemberInfo(with: peerID)
            }
        }
    }
}
