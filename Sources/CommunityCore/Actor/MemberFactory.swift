import Foundation

// MARK: - Member Factory

extension CommunitySystem {
    /// Create and register a new member with a TTY
    /// - Parameters:
    ///   - name: The member's name (must be unique)
    ///   - tty: The TTY interface to use
    ///   - ownsTTY: Whether the member should own (and close) the TTY
    /// - Returns: The created member
    /// - Throws: CommunityError.nameAlreadyTaken if name is in use
    public func createMember(name: String, tty: any TTY, ownsTTY: Bool = true) throws -> Member {
        let member = Member(name: name, tty: tty, ownsTTY: ownsTTY, actorSystem: self)
        try registerName(name, for: member.id)
        return member
    }

    /// Create and register a new member with a command (creates PTY)
    /// - Parameters:
    ///   - name: The member's name (must be unique)
    ///   - command: The command to run in the PTY
    /// - Returns: The created member
    /// - Throws: CommunityError.nameAlreadyTaken if name is in use
    public func createMember(name: String, command: String) throws -> Member {
        let member = try Member(name: name, command: command, actorSystem: self)
        try registerName(name, for: member.id)
        return member
    }
}
