import ArgumentParser
import CommunityCore
import Foundation
import PeerNode

/// Send a message to a member
public struct TellCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tell",
        abstract: "Send a message to a member"
    )

    @Argument(help: "Target member name")
    var name: String

    @Argument(help: "Message to send")
    var message: String

    @Option(name: .long, help: "Target host (default: 127.0.0.1)")
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "Target port (default: 50051)")
    var port: Int = 50051

    public init() {}

    public func run() async throws {
        // Create PeerID for the target
        let targetPeerID = PeerID(name: "target", host: host, port: port)

        // Create a temporary node for the client
        let node = PeerNode(name: "tell-client", host: "127.0.0.1", port: 0)
        try await node.start()

        let system = CommunitySystem(name: "tell-client", node: node)
        try await system.start()  // Creates SystemActor for bidirectional queries

        print("Connecting to \(host):\(port)...")
        do {
            try await system.connectToPeer(targetPeerID)
        } catch {
            print("Error: Failed to connect to \(host):\(port): \(error)")
            try await system.stop()
            throw ExitCode.failure
        }

        // Get remote system actor to find the member
        let systemActor = try system.remoteSystemActor(peerID: targetPeerID)

        print("Looking for member '\(name)'...")

        // Find the member
        guard let memberInfo = try await systemActor.findMember(name: name) else {
            print("Member '\(name)' not found")
            try await system.stop()
            throw ExitCode.failure
        }

        print("Found member: \(memberInfo.name) at \(memberInfo.peerID.value)")

        // If the member is on a different peer (different address), connect to that peer first
        if memberInfo.peerID.address != targetPeerID.address {
            print("Connecting to member's peer \(memberInfo.peerID.value)...")
            do {
                try await system.connectToPeer(memberInfo.peerID)
            } catch {
                print("Error: Failed to connect to member's peer: \(error)")
                try await system.stop()
                throw ExitCode.failure
            }
        }

        // Resolve and call the member
        do {
            let member = try Member.resolve(id: memberInfo.actorID, using: system)
            try await member.tell(message)
            print("Sent to '\(name)': \(message)")
        } catch {
            print("Failed to send message: \(error)")
            try await system.stop()
            throw ExitCode.failure
        }

        try await system.stop()
    }
}
