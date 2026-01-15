import ArgumentParser
import CommunityCore
import Foundation
import Synchronization
import PeerNode

/// Default port for community server
private let defaultPort = 50051

/// Join the community as a member with a PTY
public struct JoinCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "join",
        abstract: "Join as a member with a PTY running a command"
    )

    @Argument(help: "Command to run in the PTY (e.g., /bin/bash, claude). If omitted, uses $SHELL.")
    var command: String?

    @Option(name: .shortAndLong, help: "Member name (defaults to terminal name)")
    var name: String?

    @Option(name: .long, help: "Host address to bind (default: 127.0.0.1)")
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "Port to listen on (default: \(defaultPort))")
    var port: Int = defaultPort

    @Option(name: .long, help: "Peer to connect to (format: name@host:port)")
    var peer: [String] = []

    @Flag(name: .long, help: "Disable mDNS advertising and discovery")
    var noDiscovery: Bool = false

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

        // 1. Create and start PeerNode (always start our own server)
        var node = PeerNode(name: memberName, host: host, port: port)
        var actualPort = port

        do {
            try await node.start()
        } catch let error as PeerNodeError {
            switch error {
            case .portUnavailable(let p):
                if p == defaultPort {
                    // Default port is busy - try auto-assign
                    node = PeerNode(name: memberName, host: host, port: 0)
                    try await node.start()
                    actualPort = 0
                } else {
                    print("Error: Port \(p) is already in use")
                    throw ExitCode.failure
                }
            default:
                print("Error: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }

        guard let boundPort = node.boundPort else {
            print("Error: Failed to get bound port")
            throw ExitCode.failure
        }

        // 2. Create the CommunitySystem with the node
        let system = CommunitySystem(name: memberName, node: node)
        try await system.start()

        // 3. Create PTY and register member BEFORE connecting to peers
        //    so that exchangeMemberInfo can see this member
        let actualCommand = command ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let pty = try PTY(command: actualCommand)
        _ = try system.createMember(name: memberName, pty: pty, ownsPTY: false)

        // 4. If we're on auto-assigned port (because default was busy),
        //    try to connect to the existing server on default port
        if actualPort == 0 && port == defaultPort {
            let existingServer = PeerID(name: "existing", host: "127.0.0.1", port: defaultPort)
            do {
                try await system.connectToPeer(existingServer)
            } catch {
                // No existing server - that's fine, we're the first one
            }
        }

        // 5. Connect to specified peers
        for peerString in peer {
            guard let peerID = PeerID(peerString) else {
                print("Warning: Invalid peer format '\(peerString)', expected name@host:port")
                continue
            }
            do {
                try await system.connectToPeer(peerID)
                print("Connected to \(peerID.name)")
            } catch {
                print("Warning: Failed to connect to \(peerString): \(error)")
            }
        }

        // 6. mDNS advertising and discovery (temporarily disabled due to sandbox issues)
        // TODO: Re-enable when entitlements are configured
        // if !noDiscovery {
        //     try? await node.advertise()
        //     Task {
        //         for try await peer in await node.discover(timeout: .seconds(5)) {
        //             guard peer.peerID != node.localPeerID else { continue }
        //             try? await system.connectToPeer(peer.peerID)
        //         }
        //     }
        // }

        print("Joined as '\(memberName)' at \(host):\(boundPort)")
        if !peer.isEmpty {
            print("Connected to: \(peer.joined(separator: ", "))")
        }
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

        // PTY and Member were already created above (before peer connections)

        // Setup signal handling for SIGINT (Ctrl+C) and SIGHUP (terminal close)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let exitSemaphore = DispatchSemaphore(value: 0)

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigintSource.setEventHandler {
            exitSemaphore.signal()
        }
        sigintSource.resume()

        let sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
        sighupSource.setEventHandler {
            exitSemaphore.signal()
        }
        sighupSource.resume()

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigtermSource.setEventHandler {
            exitSemaphore.signal()
        }
        sigtermSource.resume()

        // Forward PTY output to stdout - use dedicated thread with Darwin.write
        let stdoutFD = FileHandle.standardOutput.fileDescriptor
        let outputThread = Thread { [pty] in
            let fd = pty.masterFileDescriptor
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let bytesRead = Darwin.read(fd, &readBuffer, readBuffer.count)
                if bytesRead <= 0 {
                    break
                }
                _ = readBuffer.withUnsafeBufferPointer { ptr in
                    Darwin.write(stdoutFD, ptr.baseAddress!, bytesRead)
                }
            }
        }
        outputThread.start()

        // Forward stdin to PTY - run on dedicated thread to avoid blocking async runtime
        let inputThread = Thread {
            while true {
                var buffer = [UInt8](repeating: 0, count: 256)
                let bytesRead = Darwin.read(stdinFD, &buffer, buffer.count)
                if bytesRead > 0 {
                    try? pty.writeRaw(Data(buffer[0..<bytesRead]))
                } else if bytesRead <= 0 {
                    break  // EOF or error
                }
            }
        }
        inputThread.start()

        // Wait until signal (bridges blocking wait to async context)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                exitSemaphore.wait()
                continuation.resume()
            }
        }

        // Cleanup
        print("\nLeaving...")
        sigintSource.cancel()
        sighupSource.cancel()
        sigtermSource.cancel()
        // Note: outputThread and inputThread will terminate when PTY is closed
        pty.close()
        try await system.stop()
        print("'\(memberName)' left")
    }
}
