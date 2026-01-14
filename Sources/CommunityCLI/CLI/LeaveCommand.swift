import ArgumentParser
import CommunityCore
import Foundation

/// Leave command (placeholder - actual leave is handled by Ctrl+C in join)
public struct LeaveCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "leave",
        abstract: "Leave the community (use Ctrl+C in join session)"
    )

    @Argument(help: "Member name to leave")
    var name: String

    public init() {}

    public func run() async throws {
        print("To leave, press Ctrl+C in the terminal where '\(name)' joined.")
        print("")
        print("Note: Remote leave is not yet implemented.")
        print("Each member must leave from their own terminal session.")
    }
}
