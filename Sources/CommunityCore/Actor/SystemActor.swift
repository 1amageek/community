import Foundation
import Distributed
import Peer

/// A distributed actor that provides system-level queries
///
/// This actor is automatically created by CommunitySystem and provides
/// methods to discover members on a remote peer.
public distributed actor SystemActor {
    public typealias ActorSystem = CommunitySystem

    /// Reference to the system for querying members
    private let system: CommunitySystem

    /// Well-known UUID for system actors (deterministic for discovery)
    public static let wellKnownID = "00000000-0000-0000-0000-000000000001"

    /// Create a system actor
    public init(actorSystem: CommunitySystem) {
        self.actorSystem = actorSystem
        self.system = actorSystem
    }

    // MARK: - Distributed Methods

    /// Find a member by name (searches local + remote)
    /// - Parameter name: The member's name
    /// - Returns: The member's info if found, nil otherwise
    public distributed func findMember(name: String) -> MemberInfo? {
        system.findMember(byName: name)
    }

    /// List all members known by this peer (local + remote)
    /// - Returns: Array of member information with process status
    public distributed func listMembers() async -> [MemberInfo] {
        // Return local members with status + remote members without re-fetching
        await system.localMembersWithStatus() + system.remoteMembersCached()
    }
}

// MARK: - CommunitySystem Extension

extension CommunitySystem {
    /// Create and register the system actor
    /// This should be called during system start
    @discardableResult
    public func createSystemActor() -> SystemActor {
        let actor = SystemActor(actorSystem: self)
        return actor
    }

    /// Create a reference to a remote system actor
    /// - Parameter peerID: The peer's ID (typically derived from host:port)
    /// - Returns: A proxy to the remote system actor
    public func remoteSystemActor(peerID: PeerID) throws -> SystemActor {
        let actorID = CommunityActorID(
            id: SystemActor.wellKnownID,
            peerID: peerID
        )
        return try SystemActor.resolve(id: actorID, using: self)
    }
}
