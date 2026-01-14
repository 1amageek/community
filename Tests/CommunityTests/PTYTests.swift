import Testing
import Foundation
@testable import CommunityCore

extension SerializedTestSuites {
    @Suite("PTY Tests")
    struct PTYTests {

        // MARK: - 初期化テスト

        @Test("Init with /bin/echo succeeds")
        func initWithEcho() async throws {
            let pty = try PTY(command: "/bin/echo hello")
            // echo は即座に終了するので少し待つ
            try await Task.sleep(for: .milliseconds(100))
            pty.close()
        }

        @Test("Init with empty command uses /bin/bash")
        func initWithEmptyCommand() async throws {
            let pty = try PTY(command: "")
            // bashが起動するまで少し待つ
            try await Task.sleep(for: .milliseconds(100))
            let running = pty.isRunning
            // 即座にkillして終了（close()は遅いのでkillProcessを使う）
            pty.killProcess()
            pty.close()
            #expect(running)
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
            defer { pty.close() }

            try pty.writeLine("test")

            // タイムアウト付きで読み取り
            let result = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    for await line in pty.lines {
                        return line
                    }
                    return nil
                }

                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return nil
                }

                for await result in group {
                    group.cancelAll()
                    return result
                }
                return nil
            }

            #expect(result == "test")
        }

        // MARK: - 読み取りテスト

        @Test("Lines stream reads output")
        func linesStreamReadsOutput() async throws {
            let pty = try PTY(command: "/bin/cat")
            defer { pty.close() }

            try pty.writeLine("hello")

            // タイムアウト付きで読み取り
            let result = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    for await line in pty.lines {
                        return line
                    }
                    return nil
                }

                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return nil
                }

                for await result in group {
                    group.cancelAll()
                    return result
                }
                return nil
            }

            #expect(result == "hello")
        }

        @Test("Bytes stream reads raw output")
        func bytesStreamReadsOutput() async throws {
            let pty = try PTY(command: "/bin/echo A")
            defer { pty.close() }

            // タイムアウト付きで読み取り
            let result = await withTaskGroup(of: UInt8?.self) { group in
                group.addTask {
                    for await byte in pty.bytes {
                        return byte
                    }
                    return nil
                }

                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return nil
                }

                for await result in group {
                    group.cancelAll()
                    return result
                }
                return nil
            }

            #expect(result == UInt8(ascii: "A"))
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
            // "exit 0"は即座に終了する
            let pty = try PTY(command: "exit 0")
            defer { pty.close() }

            // プロセス終了をポーリングで待つ（最大5秒）
            var exited = false
            for _ in 0..<50 {
                if !pty.isRunning {
                    exited = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }

            #expect(exited == true)
        }

        @Test("terminate sends SIGTERM")
        func terminateSendsSIGTERM() async throws {
            // exec で bash を sleep に置き換え、SIGTERM で確実に終了する
            let pty = try PTY(command: "exec sleep 60")
            defer { pty.close() }

            // プロセスが起動するのを待つ
            try await Task.sleep(for: .milliseconds(300))
            #expect(pty.isRunning)

            pty.terminate()

            // 終了をポーリングで待つ（最大5秒）
            var exited = false
            for _ in 0..<50 {
                if !pty.isRunning {
                    exited = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }

            #expect(exited == true)
        }

        @Test("killProcess sends SIGKILL")
        func killProcessSendsSIGKILL() async throws {
            let pty = try PTY(command: "/bin/cat")
            defer { pty.close() }

            pty.killProcess()

            // 終了をポーリングで待つ
            var exited = false
            for _ in 0..<30 {
                if !pty.isRunning {
                    exited = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }

            #expect(exited == true)
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

            // close()はwaitpidで子プロセスをreapするので、isRunningはfalseになる
            #expect(wasRunning == true)
            #expect(pty.isRunning == false)
        }
    }
}
