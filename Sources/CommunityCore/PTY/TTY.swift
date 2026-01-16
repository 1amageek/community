import Foundation

/// Protocol representing a teletypewriter interface
///
/// This abstracts the output mechanism for members.
public protocol TTY: Sendable {
    /// Write a line of text to the terminal
    func writeLine(_ message: String) throws

    /// Whether the underlying process/session is still running
    var isRunning: Bool { get }

    /// Close the terminal session
    func close()

    /// The command that was used to start this TTY (e.g., "zsh", "claude")
    var command: String { get }

    /// Current working directory of the process
    var cwd: String? { get }

    /// Name of the foreground process (nil if same as command)
    var foregroundProcess: String? { get }
}

// Default implementations for TTY types that don't support process info
extension TTY {
    public var command: String { "-" }
    public var cwd: String? { nil }
    public var foregroundProcess: String? { nil }
}
