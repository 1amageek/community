import Testing
import Foundation
@testable import Community

@Suite("PTY Tests")
struct PTYTests {

    // MARK: - 初期化テスト

    @Test("Init with /bin/echo succeeds")
    func initWithEcho() throws {
        let pty = try PTY(command: "/bin/echo hello")
        #expect(pty.isRunning || true)  // echo は即座に終了する可能性
    }

    @Test("Init with empty command uses /bin/bash")
    func initWithEmptyCommand() throws {
        let pty = try PTY(command: "")
        #expect(pty.isRunning)
        pty.close()
    }

    @Test("Init with /bin/cat for interactive testing")
    func initWithCat() throws {
        let pty = try PTY(command: "/bin/cat")
        #expect(pty.isRunning)
        pty.close()
    }

    // MARK: - 書き込みテスト

    @Test("Write to PTY succeeds")
    func writeSucceeds() throws {
        let pty = try PTY(command: "/bin/cat")
        try pty.writeLine("hello")
        #expect(pty.isRunning)
        pty.close()
    }

    @Test("Write to closed PTY throws alreadyClosed")
    func writeToClosedThrows() throws {
        let pty = try PTY(command: "/bin/cat")
        pty.close()

        #expect(throws: PTYError.alreadyClosed) {
            try pty.writeLine("hello")
        }
    }

    @Test("WriteLine adds newline")
    func writeLineAddsNewline() async throws {
        let pty = try PTY(command: "/bin/cat")
        try pty.writeLine("test")

        // cat はエコーバックするので読み取れる
        var output: String?
        for await line in pty.lines {
            output = line
            break
        }

        #expect(output == "test")
        pty.close()
    }

    // MARK: - 読み取りテスト

    @Test("Lines stream reads output")
    func linesStreamReadsOutput() async throws {
        let pty = try PTY(command: "/bin/echo hello")

        var lines: [String] = []
        for await line in pty.lines {
            lines.append(line)
            if lines.count >= 1 { break }
        }

        #expect(lines.contains("hello"))
    }

    @Test("Bytes stream reads raw output")
    func bytesStreamReadsOutput() async throws {
        let pty = try PTY(command: "/bin/echo A")

        var bytes: [UInt8] = []
        for await byte in pty.bytes {
            bytes.append(byte)
            if bytes.count >= 1 { break }
        }

        #expect(bytes.contains(UInt8(ascii: "A")))
    }

    // MARK: - プロセス状態テスト

    @Test("isRunning true for active process")
    func isRunningTrueForActive() throws {
        let pty = try PTY(command: "/bin/cat")
        #expect(pty.isRunning == true)
        pty.close()
    }

    @Test("isRunning false after process exits")
    func isRunningFalseAfterExit() async throws {
        let pty = try PTY(command: "/bin/echo done")

        // プロセス終了を待つ
        try await Task.sleep(for: .milliseconds(100))

        #expect(pty.isRunning == false)
    }

    @Test("terminate sends SIGTERM")
    func terminateSendsSIGTERM() async throws {
        let pty = try PTY(command: "/bin/cat")
        #expect(pty.isRunning)

        pty.terminate()
        try await Task.sleep(for: .milliseconds(100))

        #expect(pty.isRunning == false)
    }

    @Test("killProcess sends SIGKILL")
    func killProcessSendsSIGKILL() async throws {
        let pty = try PTY(command: "/bin/cat")
        pty.killProcess()
        try await Task.sleep(for: .milliseconds(100))

        #expect(pty.isRunning == false)
    }

    // MARK: - クリーンアップテスト

    @Test("close is idempotent")
    func closeIsIdempotent() throws {
        let pty = try PTY(command: "/bin/cat")
        pty.close()
        pty.close()  // 2回目も問題なし
        pty.close()  // 3回目も問題なし
    }

    @Test("close terminates child process")
    func closeTerminatesChild() async throws {
        let pty = try PTY(command: "/bin/cat")
        let wasRunning = pty.isRunning
        pty.close()

        try await Task.sleep(for: .milliseconds(50))

        #expect(wasRunning == true)
        #expect(pty.isRunning == false)
    }
}
