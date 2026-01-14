import ArgumentParser
import Foundation
import Discovery

/// List all members in the community
public struct ListCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all members in the community"
    )

    @Option(name: .shortAndLong, help: "Discovery timeout in seconds")
    var timeout: Int = 3

    @Option(name: .shortAndLong, help: "Target host")
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "Target port")
    var port: Int = 50051

    @Option(name: .long, help: "Additional peer hosts (comma-separated host:port)")
    var peers: String = ""

    public init() {}

    public func run() async throws {
        // Create the actor system
        let system = CommunitySystem()

        // Build known peers list - always include default localhost peer
        var knownPeers: [GRPCTransport.PeerEndpoint] = [
            GRPCTransport.PeerEndpoint(
                peerID: PeerID("peer-\(host)-\(port)"),
                host: host,
                port: port
            )
        ]

        // Parse additional peers
        if !peers.isEmpty {
            for peerStr in peers.split(separator: ",") {
                let parts = peerStr.split(separator: ":")
                if parts.count == 2, let peerPort = Int(parts[1]) {
                    let peerHost = String(parts[0])
                    knownPeers.append(GRPCTransport.PeerEndpoint(
                        peerID: PeerID("peer-\(peerHost)-\(peerPort)"),
                        host: peerHost,
                        port: peerPort
                    ))
                }
            }
        }

        // Create gRPC transport (client-only mode)
        let transport = GRPCTransport(
            localPeerInfo: system.localPeerInfo,
            config: GRPCTransport.Configuration(
                knownPeers: knownPeers,
                serverEnabled: false  // Client-only mode
            )
        )

        print("Connecting to \(host):\(port)...")

        // Start the system
        do {
            try await system.start(transports: [transport])
            print("Connected.")
        } catch {
            print("Connection failed: \(error)")
            throw error
        }

        print("Discovering members...")
        print("")

        // Discover members with specified timeout
        let members: [MemberInfo]
        do {
            members = try await system.discoverMembers(timeout: timeout)
        } catch {
            print("Discovery failed: \(error)")
            throw error
        }

        if members.isEmpty {
            print("No members found")
        } else {
            // Print header
            print("\("NAME".padding(toLength: 15, withPad: " ", startingAt: 0))\("PEER".padding(toLength: 15, withPad: " ", startingAt: 0))\("TRANSPORT".padding(toLength: 10, withPad: " ", startingAt: 0))")
            print(String(repeating: "-", count: 42))

            // Print members
            for member in members {
                let name = member.name.padding(toLength: 15, withPad: " ", startingAt: 0)
                let peer = member.peerID.value.padding(toLength: 15, withPad: " ", startingAt: 0)
                let transport = member.transport.padding(toLength: 10, withPad: " ", startingAt: 0)
                print("\(name)\(peer)\(transport)")
            }
        }

        try await system.stop()
    }
}
