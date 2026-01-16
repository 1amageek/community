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

        let systemActor = try system.remoteSystemActor(peerID: targetPeerID)
        let members = try await systemActor.listMembers()
        try await system.stop()

        if members.isEmpty {
            print("No members registered")
        } else {
            // Check if we're running inside an mm join session
            let selfName = ProcessInfo.processInfo.environment["MM_NAME"]

            // Print header
            print("  \("NAME".padding(toLength: 20, withPad: " ", startingAt: 0))\("PEER".padding(toLength: 30, withPad: " ", startingAt: 0))")
            print(String(repeating: "-", count: 52))

            // Print members
            for member in members {
                let isSelf = (selfName != nil && member.name == selfName)
                let marker = isSelf ? "* " : "  "
                let name = member.name.padding(toLength: 20, withPad: " ", startingAt: 0)
                let peerStr = member.peerID.value.padding(toLength: 30, withPad: " ", startingAt: 0)
                print("\(marker)\(name)\(peerStr)")
            }
        }
    }
}
