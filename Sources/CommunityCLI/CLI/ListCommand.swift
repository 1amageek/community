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
        do {
            try await system.connectToPeer(targetPeerID)
        } catch {
            print("Error: Failed to connect to \(host):\(port): \(error)")
            try await system.stop()
            throw ExitCode.failure
        }

        let systemActor = try system.remoteSystemActor(peerID: targetPeerID)
        let members = try await systemActor.listMembers()
        try await system.stop()

        if members.isEmpty {
            print("No members registered")
        } else {
            // Print header
            print("\("NAME".padding(toLength: 20, withPad: " ", startingAt: 0))\("PEER".padding(toLength: 30, withPad: " ", startingAt: 0))")
            print(String(repeating: "-", count: 50))

            // Print members
            for member in members {
                let name = member.name.padding(toLength: 20, withPad: " ", startingAt: 0)
                let peerStr = member.peerID.value.padding(toLength: 30, withPad: " ", startingAt: 0)
                print("\(name)\(peerStr)")
            }
        }
    }
}
