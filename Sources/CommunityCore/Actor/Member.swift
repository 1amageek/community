import Foundation
import Distributed
import Peer

/// A distributed actor representing a member in the community
///
/// Each member has a TTY (teletypewriter) interface for communication.
/// This can be a PTY (pseudo-terminal) for new sessions, or a StdoutTTY
/// for attached sessions. Other members can send messages via `tell`.
public distributed actor Member {
    public typealias ActorSystem = CommunitySystem

    /// The member's display name
    public let name: String

    /// The TTY interface for this member
    private let tty: any TTY

    /// Whether this member owns the TTY (should close on deinit)
    private let ownsTTY: Bool

    /// Create a new member with a TTY interface
    /// - Parameters:
    ///   - name: The member's name
    ///   - tty: The TTY interface to use
    ///   - ownsTTY: Whether this member owns the TTY (defaults to true)
    ///   - actorSystem: The distributed actor system
    public init(name: String, tty: any TTY, ownsTTY: Bool = true, actorSystem: CommunitySystem) {
        self.name = name
        self.tty = tty
        self.ownsTTY = ownsTTY
        self.actorSystem = actorSystem
    }

    /// Create a new member with a command (creates a PTY)
    /// - Parameters:
    ///   - name: The member's name
    ///   - command: The command to run in the PTY
    ///   - actorSystem: The distributed actor system
    public init(name: String, command: String, actorSystem: CommunitySystem) throws {
        self.name = name
        self.tty = try PTY(command: command)
        self.ownsTTY = true
        self.actorSystem = actorSystem
    }

    // MARK: - Distributed Methods

    /// Send a message to this member's terminal
    /// - Parameter message: The message to send
    public distributed func tell(_ message: String) throws {
        try tty.writeLine(message)
    }

    /// Check if the member's session is still running
    public distributed func isRunning() -> Bool {
        tty.isRunning
    }

    /// Get the member's name
    public distributed func getName() -> String {
        name
    }

    // MARK: - Lifecycle

    deinit {
        if ownsTTY {
            tty.close()
        }
    }
}
