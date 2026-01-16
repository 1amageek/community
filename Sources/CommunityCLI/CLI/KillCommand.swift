import ArgumentParser
import Foundation
import CommunityCore
import PeerNode

/// Kill/disconnect mm peers
public struct KillCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "kill",
        abstract: "Disconnect peers or kill mm join processes",
        discussion: """
        Disconnect specific peers from the mesh, or kill mm join processes.

        Examples:
          mm kill codex@127.0.0.1:50051                    # Disconnect one peer
          mm kill codex@127.0.0.1:50051 bob@127.0.0.1:50051  # Disconnect multiple peers
          mm kill --all                                    # Kill all mm join processes
          mm kill --all -f                                 # Force kill (SIGKILL)
        """
    )

    @Argument(help: "Peer IDs to disconnect (e.g., codex@127.0.0.1:50051)")
    var peers: [String] = []

    @Flag(name: .long, help: "Kill all mm join processes")
    var all: Bool = false

    @Flag(name: .shortAndLong, help: "Force kill (SIGKILL instead of SIGTERM)")
    var force: Bool = false

    public init() {}

    public func run() async throws {
        if all {
            try await killAllProcesses()
        } else if !peers.isEmpty {
            try await disconnectPeers(peers)
        } else {
            print("Usage: mm kill <peer-id>... or mm kill --all")
            print("Run 'mm kill --help' for more information.")
        }
    }

    private func disconnectPeers(_ peerStrs: [String]) async throws {
        // Parse and validate peer IDs
        var validPeers: [(str: String, id: PeerID)] = []
        for peerStr in peerStrs {
            if let peerID = PeerID(peerStr) {
                validPeers.append((str: peerStr, id: peerID))
            } else {
                print("Warning: Invalid peer ID format '\(peerStr)' - skipping")
                print("  Expected format: name@host:port (e.g., codex@127.0.0.1:50051)")
            }
        }

        if validPeers.isEmpty {
            print("No valid peer IDs provided")
            return
        }

        // Group peers by server (host:port)
        var peersByServer: [String: [(str: String, id: PeerID)]] = [:]
        for peer in validPeers {
            let serverKey = "\(peer.id.host):\(peer.id.port)"
            peersByServer[serverKey, default: []].append(peer)
        }

        // Process each server
        for (serverKey, peersOnServer) in peersByServer {
            guard let firstPeer = peersOnServer.first else { continue }

            // Connect to this server
            let node = PeerNode(name: "kill-cmd", port: 0)
            do {
                try await node.start()
            } catch {
                print("Warning: Could not start node for server \(serverKey) - skipping")
                continue
            }

            let system = CommunitySystem(name: "kill-cmd", node: node)
            try await system.start()

            let serverPeerID = PeerID(name: "server", host: firstPeer.id.host, port: firstPeer.id.port)
            do {
                try await system.connectToPeer(serverPeerID)
            } catch {
                print("Warning: Could not connect to mm server at \(serverKey) - skipping")
                try await system.stop()
                await node.stop()
                continue
            }

            // Disconnect each peer on this server
            for peer in peersOnServer {
                await system.disconnectPeer(peer.id)
                print("Disconnected: \(peer.str)")
            }

            try await system.stop()
            await node.stop()
        }
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

        // Parse PIDs of mm join processes
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var pidsToKill: [pid_t] = []

        for line in output.split(separator: "\n") {
            let lineStr = String(line).trimmingCharacters(in: .whitespaces)

            // Match "mm join" in the command
            if lineStr.contains("mm join") {
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
