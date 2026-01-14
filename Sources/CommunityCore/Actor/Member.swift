import Foundation
import Distributed
import Peer

/// A distributed actor representing a member in the community
///
/// Each member has a PTY (pseudo-terminal) that can run arbitrary commands.
/// Other members can send messages to this member via the `tell` method.
public distributed actor Member {
    public typealias ActorSystem = CommunitySystem

    /// The member's display name
    public let name: String

    /// The PTY running the member's command
    private let pty: PTY

    /// Whether the PTY is owned by this member (should close on deinit)
    private let ownsPTY: Bool

    /// Create a new member with a specific name and an existing PTY
    /// - Parameters:
    ///   - name: The member's name
    ///   - pty: The PTY to use
    ///   - ownsPTY: Whether this member owns the PTY (defaults to true)
    ///   - actorSystem: The distributed actor system
    public init(name: String, pty: PTY, ownsPTY: Bool = true, actorSystem: CommunitySystem) {
        self.name = name
        self.pty = pty
        self.ownsPTY = ownsPTY
        self.actorSystem = actorSystem
    }

    /// Create a new member with a specific name and command
    /// - Parameters:
    ///   - name: The member's name
    ///   - command: The command to run in the PTY
    ///   - actorSystem: The distributed actor system
    public init(name: String, command: String, actorSystem: CommunitySystem) throws {
        self.name = name
        self.actorSystem = actorSystem
        self.ownsPTY = true

        // Create PTY with the specified command
        self.pty = try PTY(command: command)
    }

    // MARK: - Distributed Methods

    /// Send a message to this member's PTY
    /// - Parameter message: The message to send
    public distributed func tell(_ message: String) throws {
        try pty.writeLine(message)
    }

    /// Check if the member's process is still running
    public distributed func isRunning() -> Bool {
        pty.isRunning
    }

    /// Get the member's name
    public distributed func getName() -> String {
        name
    }

    // MARK: - Lifecycle

    deinit {
        if ownsPTY {
            pty.close()
        }
    }
}

// MARK: - Member Factory

extension CommunitySystem {
    /// Create and register a new member with an existing PTY
    /// - Parameters:
    ///   - name: The member's name (must be unique)
    ///   - pty: The PTY to use
    ///   - ownsPTY: Whether the member should own (and close) the PTY
    /// - Returns: The created member
    /// - Throws: CommunityError.nameAlreadyTaken if name is in use
    public func createMember(name: String, pty: PTY, ownsPTY: Bool = true) throws -> Member {
        let member = Member(name: name, pty: pty, ownsPTY: ownsPTY, actorSystem: self)
        // Register name → actorID mapping
        try registerName(name, for: member.id)
        return member
    }

    /// Create and register a new member with a new PTY
    /// - Parameters:
    ///   - name: The member's name (must be unique)
    ///   - command: The command to run in the PTY
    /// - Returns: The created member
    /// - Throws: CommunityError.nameAlreadyTaken if name is in use
    public func createMember(name: String, command: String) throws -> Member {
        let member = try Member(name: name, command: command, actorSystem: self)
        // Register name → actorID mapping
        try registerName(name, for: member.id)
        return member
    }
}
