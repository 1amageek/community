import Foundation
import Peer

/// Actor identifier for the Community distributed actor system
///
/// The ID is composed of:
/// - `id`: A unique identifier (UUID) for the actor instance
/// - `peerID`: The host peer where this actor lives
///
/// Note: The actor's "name" (e.g., "alice") is an alias managed separately.
public struct CommunityActorID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Unique identifier for this actor instance
    public let id: String

    /// Host peer where this actor lives
    public let peerID: PeerID

    /// Create an actor ID with a specific UUID
    public init(id: String, peerID: PeerID) {
        self.id = id
        self.peerID = peerID
    }

    /// Create a new actor ID with an auto-generated UUID
    public init(peerID: PeerID) {
        self.id = UUID().uuidString
        self.peerID = peerID
    }

    /// String representation: "id@peer"
    public var description: String {
        "\(id.prefix(8))@\(peerID.value)"
    }
}

// MARK: - Codable

extension CommunityActorID {
    enum CodingKeys: String, CodingKey {
        case id
        case peerID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.peerID = try container.decode(PeerID.self, forKey: .peerID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(peerID, forKey: .peerID)
    }
}
