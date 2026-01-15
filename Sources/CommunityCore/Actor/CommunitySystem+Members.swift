import Foundation
import PeerNode

// MARK: - Name Registry

extension CommunitySystem {
    /// Register a name alias for an actor
    public func registerName(_ name: String, for actorID: ActorID) throws {
        try nameRegistry.register(name: name, actorID: actorID)
    }

    /// Unregister a name alias
    public func unregisterName(_ name: String) {
        nameRegistry.unregister(name: name)
    }

    /// Find actor ID by name (local only)
    public func findLocalActorID(byName name: String) -> ActorID? {
        nameRegistry.find(name: name)
    }

    /// Get all registered names (local only)
    public func allLocalNames() -> [String] {
        nameRegistry.allNames()
    }
}

// MARK: - Member Management

extension CommunitySystem {
    /// Get all local members
    public func localMembers() -> [MemberInfo] {
        nameRegistry.allEntries().map { (name, actorID) in
            MemberInfo(
                name: name,
                actorID: actorID,
                peerID: localPeerInfo.peerID,
                transport: "local"
            )
        }
    }

    /// Get all members (local + remote)
    public func allMembers() -> [MemberInfo] {
        let local = localMembers()
        let remote = state.withLock { Array($0.remoteMembers.values) }
        var members = local
        members.append(contentsOf: remote)
        return members
    }

    /// Find a member by name (searches local + remote)
    /// - Parameter name: The member name to search for
    /// - Returns: MemberInfo if found, nil otherwise
    public func findMember(byName name: String) -> MemberInfo? {
        // First check local
        if let actorID = nameRegistry.find(name: name) {
            return MemberInfo(
                name: name,
                actorID: actorID,
                peerID: localPeerInfo.peerID,
                transport: "local"
            )
        }
        // Then check remote
        return state.withLock { s in
            s.remoteMembers.values.first { $0.name == name }
        }
    }
}
