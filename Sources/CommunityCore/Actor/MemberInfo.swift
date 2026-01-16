import Foundation
import Peer

/// Information about a discovered member
public struct MemberInfo: Sendable, Codable {
    public let name: String
    public let actorID: CommunityActorID
    public let peerID: PeerID
    public let transport: String

    /// The command running in this member's PTY (e.g., "zsh", "claude")
    public let command: String?

    /// Current working directory of the member's process
    public let cwd: String?

    /// Name of the foreground process (nil if same as command)
    public let foregroundProcess: String?

    public init(
        name: String,
        actorID: CommunityActorID,
        peerID: PeerID,
        transport: String = "local",
        command: String? = nil,
        cwd: String? = nil,
        foregroundProcess: String? = nil
    ) {
        self.name = name
        self.actorID = actorID
        self.peerID = peerID
        self.transport = transport
        self.command = command
        self.cwd = cwd
        self.foregroundProcess = foregroundProcess
    }
}
