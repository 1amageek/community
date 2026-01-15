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
}
