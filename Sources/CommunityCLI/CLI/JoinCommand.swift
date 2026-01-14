import ArgumentParser
import CommunityCore
import Foundation
import Synchronization

/// Join the community as a member with a PTY
public struct JoinCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "join",
        abstract: "Join as a member with a PTY running a command"
    )

    @Argument(help: "Command to run in the PTY (e.g., /bin/bash, claude)")
    var command: String

    @Option(name: .shortAndLong, help: "Member name (defaults to terminal name)")
    var name: String?

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 50051

    public init() {}

    /// Get member name from option or derive from terminal
    private func getMemberName() -> String {
        if let name = name {
            return name
        }

        // Try to get TTY name
        let stdinFD = FileHandle.standardInput.fileDescriptor
        if let ttyPath = String(cString: ttyname(stdinFD), encoding: .utf8) {
            // Extract just the tty name (e.g., "/dev/ttys001" -> "ttys001")
            let ttyName = (ttyPath as NSString).lastPathComponent
            return ttyName
        }

        // Fallback to hostname + PID
        return "\(ProcessInfo.processInfo.hostName)-\(ProcessInfo.processInfo.processIdentifier)"
    }

    public func run() async throws {
        let memberName = getMemberName()

        // Create the actor system
        let system = CommunitySystem(name: memberName)

        // Create and start gRPC transport
        let transport = GRPCTransport(
            configuration: .server(port: port)
        )
        try await transport.open()

        // Start the system with the transport
        try await system.start(transport: transport)

        // Create system actor for remote queries
        _ = system.createSystemActor()

        print("Joined as '\(memberName)' running '\(command)' on port \(port)")
        print("Press Ctrl+C to leave")
        print("")

        // Save original terminal settings and set raw mode
        let stdinFD = FileHandle.standardInput.fileDescriptor
        var originalTermios = termios()
        tcgetattr(stdinFD, &originalTermios)

        var rawTermios = originalTermios
        cfmakeraw(&rawTermios)
        tcsetattr(stdinFD, TCSANOW, &rawTermios)

        defer {
            // Restore terminal settings
            tcsetattr(stdinFD, TCSANOW, &originalTermios)
        }

        // Create PTY
        let pty = try PTY(command: command)

        // Create member with the PTY (for remote `tell` access)
        // Member does NOT own the PTY since we manage I/O here
        _ = try system.createMember(name: memberName, pty: pty, ownsPTY: false)

        // Setup signal handling
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let shouldExit = Mutex(false)

        sigintSource.setEventHandler {
            shouldExit.withLock { $0 = true }
        }
        sigintSource.resume()

        // Forward PTY output to stdout - raw bytes
        let outputTask = Task {
            for await byte in pty.bytes {
                FileHandle.standardOutput.write(Data([byte]))
            }
        }

        // Forward stdin to PTY - read raw bytes and write directly
        let inputTask = Task {
            while !shouldExit.withLock({ $0 }) {
                var buffer = [UInt8](repeating: 0, count: 256)
                let bytesRead = Darwin.read(stdinFD, &buffer, buffer.count)
                if bytesRead > 0 {
                    try? pty.writeRaw(Data(buffer[0..<bytesRead]))
                } else if bytesRead == 0 {
                    break  // EOF
                }
            }
        }

        // Wait until SIGINT
        while !shouldExit.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(100))
        }

        // Cleanup
        print("\nLeaving...")
        sigintSource.cancel()
        inputTask.cancel()
        outputTask.cancel()
        pty.close()
        try await system.stop()
        print("'\(memberName)' left")
    }
}
