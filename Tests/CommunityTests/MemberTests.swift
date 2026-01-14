import Testing
import Foundation
import Peer
@testable import CommunityCore

@Suite("Member Tests")
struct MemberTests {

    // MARK: - 初期化テスト

    @Test("Init with PTY succeeds")
    func initWithPTY() async throws {
        let system = CommunitySystem(name: "test")

        let pty = try PTY(command: "/bin/cat")
        let member = Member(name: "alice", pty: pty, actorSystem: system)

        #expect(try await member.getName() == "alice")

        pty.close()
    }

    @Test("Init with command creates PTY")
    func initWithCommand() async throws {
        let system = CommunitySystem(name: "test")

        let member = try Member(name: "bob", command: "/bin/cat", actorSystem: system)

        #expect(try await member.isRunning() == true)
    }

    // MARK: - distributed メソッドテスト

    @Test("tell writes to PTY")
    func tellWritesToPTY() async throws {
        let system = CommunitySystem(name: "test")

        let pty = try PTY(command: "/bin/cat")
        let member = try system.createMember(name: "alice", pty: pty, ownsPTY: false)

        try await member.tell("hello")

        // cat がエコーバックするのを確認
        var output: String?
        for await line in pty.lines {
            output = line
            break
        }

        #expect(output == "hello")

        pty.close()
    }

    @Test("isRunning returns correct status")
    func isRunningReturnsCorrect() async throws {
        let system = CommunitySystem(name: "test")

        let member = try system.createMember(name: "alice", command: "/bin/cat")

        #expect(try await member.isRunning() == true)
    }

    @Test("getName returns member name")
    func getNameReturnsMemberName() async throws {
        let system = CommunitySystem(name: "test")

        let member = try system.createMember(name: "alice", command: "/bin/cat")

        #expect(try await member.getName() == "alice")
    }

    // MARK: - ファクトリメソッドテスト

    @Test("createMember registers name")
    func createMemberRegistersName() async throws {
        let system = CommunitySystem(name: "test")

        let pty = try PTY(command: "/bin/cat")
        let member = try system.createMember(name: "alice", pty: pty)

        #expect(system.findLocalActorID(byName: "alice") == member.id)

        pty.close()
    }

    @Test("createMember throws if name taken")
    func createMemberThrowsIfNameTaken() async throws {
        let system = CommunitySystem(name: "test")

        let pty1 = try PTY(command: "/bin/cat")
        _ = try system.createMember(name: "alice", pty: pty1)

        let pty2 = try PTY(command: "/bin/cat")

        #expect {
            _ = try system.createMember(name: "alice", pty: pty2)
        } throws: { error in
            guard let communityError = error as? CommunityError else { return false }
            if case .nameAlreadyTaken("alice") = communityError {
                return true
            }
            return false
        }

        pty1.close()
        pty2.close()
    }

    // MARK: - PTY所有権テスト

    @Test("Member with ownsPTY=false doesn't close PTY on deinit")
    func memberNotOwnsPTYDoesntClose() async throws {
        let system = CommunitySystem(name: "test")

        let pty = try PTY(command: "/bin/cat")

        do {
            _ = try system.createMember(name: "alice", pty: pty, ownsPTY: false)
        }

        // deinit を待つ
        try await Task.sleep(for: .milliseconds(100))

        // PTY はまだ開いている（書き込みできる）
        try pty.writeLine("still open")

        pty.close()
    }
}
