import Foundation
import Peer

/// Information about a discovered member
public struct MemberInfo: Sendable, Codable {
    public let name: String
    public let actorID: CommunityActorID
    public let peerID: PeerID
    public let transport: String

    public init(name: String, actorID: CommunityActorID, peerID: PeerID, transport: String = "local") {
        self.name = name
        self.actorID = actorID
        self.peerID = peerID
        self.transport = transport
    }
}
