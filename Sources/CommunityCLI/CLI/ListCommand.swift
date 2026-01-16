import ArgumentParser
import CommunityCore
import Foundation
import PeerNode

/// List all members in the community
public struct ListCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List members in the community"
    )

    @Option(name: .long, help: "Target host (default: 127.0.0.1)")
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "Target port (default: 50051)")
    var port: Int = 50051

    public init() {}

    public func run() async throws {
        // Create PeerID for the target
        let targetPeerID = PeerID(name: "target", host: host, port: port)

        // Create a temporary node for the client
        let node = PeerNode(name: "list-client", host: "127.0.0.1", port: 0)
        try await node.start()

        let system = CommunitySystem(name: "list-client", node: node)
        try await system.start()  // Creates SystemActor for bidirectional queries

        print("Connecting to \(host):\(port)...")

        // Connect with timeout
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await system.connectToPeer(targetPeerID)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw CommunityError.connectionTimeout
                }
                // Wait for first to complete (connection or timeout)
                try await group.next()
                group.cancelAll()
            }
        } catch is CommunityError {
            print("Error: Failed to connect to \(host):\(port)")
            print("  Connection timed out (no server running?)")
            try await system.stop()
            throw ExitCode.failure
        } catch {
            print("Error: Failed to connect to \(host):\(port)")
            print("  \(error)")
            try await system.stop()
            throw ExitCode.failure
        }

        // Get members via list-client's own system (includes remote members from connected peers)
        let members = await system.allMembersWithStatus()
        try await system.stop()

        if members.isEmpty {
            print("No members registered")
        } else {
            // Check if we're running inside an mm join session
            let selfName = ProcessInfo.processInfo.environment["MM_NAME"]

            // Print header
            let nameCol = "NAME".padding(toLength: 12, withPad: " ", startingAt: 0)
            let peerCol = "PEER".padding(toLength: 28, withPad: " ", startingAt: 0)
            let cmdCol = "COMMAND".padding(toLength: 10, withPad: " ", startingAt: 0)
            let procCol = "PROCESS".padding(toLength: 10, withPad: " ", startingAt: 0)
            let cwdCol = "CWD"

            print("  \(nameCol)\(peerCol)\(cmdCol)\(procCol)\(cwdCol)")
            print(String(repeating: "-", count: 100))

            // Print members
            for member in members {
                let isSelf = (selfName != nil && member.name == selfName)
                let marker = isSelf ? "* " : "  "

                let name = member.name.padding(toLength: 12, withPad: " ", startingAt: 0)
                let peerStr = member.peerID.value.padding(toLength: 28, withPad: " ", startingAt: 0)
                let cmd = (member.command ?? "-").padding(toLength: 10, withPad: " ", startingAt: 0)
                let proc = (member.foregroundProcess ?? "-").padding(toLength: 10, withPad: " ", startingAt: 0)
                let cwd = formatCWD(member.cwd)

                print("\(marker)\(name)\(peerStr)\(cmd)\(proc)\(cwd)")
            }
        }
    }

    /// Format CWD for display (replace home with ~, truncate if needed)
    private func formatCWD(_ cwd: String?) -> String {
        guard let cwd = cwd else { return "-" }

        // Replace home directory with ~
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var display = cwd
        if cwd.hasPrefix(home) {
            display = "~" + cwd.dropFirst(home.count)
        }

        // Truncate from left if too long
        if display.count > 35 {
            display = "..." + String(display.suffix(32))
        }

        return display
    }
}
