import ArgumentParser
import Foundation
import CommunityCore
import PeerNode

/// Kill/disconnect mm peers
public struct KillCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "kill",
        abstract: "Disconnect peers or kill mm processes",
        discussion: """
        Disconnect a specific peer from the mesh, or kill all mm processes.

        Examples:
          mm kill ttys000@127.0.0.1:50051   # Disconnect this peer
          mm kill --all                      # Kill all mm processes
          mm kill --all -f                   # Force kill all (SIGKILL)
        """
    )

    @Argument(help: "Peer ID to disconnect (e.g., ttys000@127.0.0.1:50051)")
    var peer: String?

    @Flag(name: .long, help: "Kill all mm processes instead of disconnecting")
    var all: Bool = false

    @Flag(name: .shortAndLong, help: "Force kill (SIGKILL instead of SIGTERM)")
    var force: Bool = false

    public init() {}

    public func run() async throws {
        if all {
            try await killAllProcesses()
        } else if let peerStr = peer {
            try await disconnectPeer(peerStr)
        } else {
            print("Usage: mm kill <peer-id> or mm kill --all")
            print("Run 'mm kill --help' for more information.")
        }
    }

    private func disconnectPeer(_ peerStr: String) async throws {
        // Parse peer ID
        guard let peerID = PeerID(peerStr) else {
            print("Invalid peer ID format: \(peerStr)")
            print("Expected format: name@host:port (e.g., ttys000@127.0.0.1:50051)")
            return
        }

        // Connect to local server
        let node = PeerNode(name: "kill-cmd", port: 0)
        try await node.start()
        defer { Task { await node.stop() } }

        let system = CommunitySystem(name: "kill-cmd", node: node)
        try await system.start()

        // Connect to local server to get access to the mesh
        let localServer = PeerID(name: "server", host: "127.0.0.1", port: 50051)
        do {
            try await system.connectToPeer(localServer)
        } catch {
            print("Error: Could not connect to local mm server")
            print("Make sure an mm process is running.")
            return
        }

        // Disconnect the target peer
        await system.disconnectPeer(peerID)
        print("Disconnected: \(peerStr)")

        try await system.stop()
    }

    private func killAllProcesses() async throws {
        // Use ps to find mm processes
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-eo", "pid,command"]

        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice

        try ps.run()

        // Read output first to avoid deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            print("No mm processes found")
            return
        }

        // Parse PIDs of mm join/attach processes
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var pidsToKill: [pid_t] = []

        for line in output.split(separator: "\n") {
            let lineStr = String(line).trimmingCharacters(in: .whitespaces)

            // Match "mm join" or "mm attach" in the command
            if lineStr.contains("mm join") || lineStr.contains("mm attach") {
                let parts = lineStr.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if let pidStr = parts.first, let pid = pid_t(pidStr) {
                    if pid != currentPID {
                        pidsToKill.append(pid)
                    }
                }
            }
        }

        if pidsToKill.isEmpty {
            print("No mm processes found")
            return
        }

        // Kill processes
        let signal: Int32 = force ? SIGKILL : SIGTERM
        var killed: [pid_t] = []

        for pid in pidsToKill {
            if Darwin.kill(pid, signal) == 0 {
                killed.append(pid)
            }
        }

        if killed.isEmpty {
            print("Failed to kill any processes")
        } else {
            print("Killed: \(killed.map(String.init).joined(separator: ", "))")
        }
    }
}
