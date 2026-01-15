import Foundation
import Darwin

extension Array where Element == String {
    func withCStrings<R>(_ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var cStrings = self.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.compactMap { $0 }.forEach { free($0) } }
        return body(cStrings)
    }
}

public enum PTYError: Error, Sendable, Equatable {
    case openFailed(Int32)
    case grantFailed(Int32)
    case unlockFailed(Int32)
    case ptsnameFailed(Int32)
    case slaveFailed(Int32)
    case forkFailed(Int32)
    case encodingFailed
    case writeFailed(Int32)
    case alreadyClosed
}

public final class PTY: @unchecked Sendable {
    private let masterFD: Int32
    private let childPID: pid_t
    private let childPGID: pid_t
    private let readHandle: FileHandle
    private let writeHandle: FileHandle
    private var isClosed = false
    private let lock = NSLock()

    /// Expose master file descriptor for direct I/O
    public var masterFileDescriptor: Int32 { masterFD }

    public init(command: String) throws {
        // Create pipe for communication
        var masterPty: Int32 = -1
        var slavePty: Int32 = -1

        // Open master PTY
        masterPty = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterPty >= 0 else {
            throw PTYError.openFailed(errno)
        }

        guard grantpt(masterPty) == 0 else {
            Darwin.close(masterPty)
            throw PTYError.grantFailed(errno)
        }

        guard unlockpt(masterPty) == 0 else {
            Darwin.close(masterPty)
            throw PTYError.unlockFailed(errno)
        }

        guard let slaveName = ptsname(masterPty) else {
            Darwin.close(masterPty)
            throw PTYError.ptsnameFailed(errno)
        }
        let slaveNameStr = String(cString: slaveName)

        slavePty = Darwin.open(slaveNameStr, O_RDWR)
        guard slavePty >= 0 else {
            Darwin.close(masterPty)
            throw PTYError.slaveFailed(errno)
        }

        // Setup spawn attributes
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // POSIX_SPAWN_SETPGROUP: 新しいプロセスグループを作成
        // POSIX_SPAWN_CLOEXEC_DEFAULT: 親のファイルディスクリプタを継承しない（サーバーソケット等）
        let flags = Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)  // 自身のPIDをプロセスグループIDに

        // Setup file actions to redirect stdio to slave PTY
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slavePty, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slavePty, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slavePty, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, masterPty)
        posix_spawn_file_actions_addclose(&fileActions, slavePty)

        // Prepare command
        let shell = command.isEmpty ? "/bin/bash" : command
        let args = ["/bin/bash", "-c", shell]  // TODO: -l を戻す

        // Spawn process
        var pid: pid_t = 0
        let result = args.withCStrings { cArgs in
            posix_spawn(&pid, "/bin/bash", &fileActions, &attr, cArgs, environ)
        }

        // Cleanup spawn resources
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)

        // Close slave in parent
        Darwin.close(slavePty)

        guard result == 0 else {
            Darwin.close(masterPty)
            throw PTYError.forkFailed(Int32(result))
        }

        self.masterFD = masterPty
        self.childPID = pid
        var pgid = getpgid(pid)
        if pgid <= 0 {
            _ = setpgid(pid, pid)
            pgid = getpgid(pid)
        }
        self.childPGID = pgid > 0 ? pgid : pid
        self.readHandle = FileHandle(fileDescriptor: masterPty, closeOnDealloc: false)
        self.writeHandle = FileHandle(fileDescriptor: masterPty, closeOnDealloc: false)
    }

    // MARK: - Async Read

    public var lines: AsyncStream<String> {
        AsyncStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish()
                return
            }

            let fd = self.masterFD
            DispatchQueue.global().async {
                var buffer = Data()
                var readBuffer = [UInt8](repeating: 0, count: 1024)

                while true {
                    let bytesRead = read(fd, &readBuffer, readBuffer.count)
                    if bytesRead <= 0 {
                        break
                    }

                    for i in 0..<bytesRead {
                        let byte = readBuffer[i]
                        buffer.append(byte)

                        if byte == UInt8(ascii: "\n") {
                            if let line = String(data: buffer, encoding: .utf8) {
                                let trimmed = line.trimmingCharacters(in: .newlines)
                                continuation.yield(trimmed)
                            }
                            buffer.removeAll()
                        }
                    }
                }

                // Yield remaining buffer
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                    continuation.yield(line)
                }

                continuation.finish()
            }
        }
    }

    public var bytes: AsyncStream<UInt8> {
        AsyncStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish()
                return
            }

            let fd = self.masterFD
            DispatchQueue.global().async {
                var readBuffer = [UInt8](repeating: 0, count: 1024)

                while true {
                    let bytesRead = read(fd, &readBuffer, readBuffer.count)
                    if bytesRead <= 0 {
                        break
                    }

                    for i in 0..<bytesRead {
                        continuation.yield(readBuffer[i])
                    }
                }

                continuation.finish()
            }
        }
    }

    // MARK: - Async Write

    public func write(_ string: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else {
            throw PTYError.alreadyClosed
        }

        guard let data = string.data(using: .utf8) else {
            throw PTYError.encodingFailed
        }

        try writeHandle.write(contentsOf: data)
    }

    public func writeLine(_ string: String) throws {
        guard let stringData = string.data(using: .utf8) else {
            throw PTYError.encodingFailed
        }
        // Send string first, then Enter with delay for TUI apps
        try writeRaw(stringData)
        usleep(10000)  // 10ms delay before Enter
        try writeRaw(Data([0x0D]))  // Send Enter (\r)
    }

    public func writeRaw(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else {
            throw PTYError.alreadyClosed
        }

        _ = data.withUnsafeBytes { ptr in
            Darwin.write(masterFD, ptr.baseAddress!, data.count)
        }
    }

    // MARK: - Process Control

    public var isRunning: Bool {
        // まず waitpid で状態を確認（ゾンビプロセスをreapする）
        var status: Int32 = 0
        let waitResult = waitpid(childPID, &status, WNOHANG)

        if waitResult > 0 {
            // プロセスが終了した（reapされた）
            return false
        }

        if waitResult == -1 {
            // エラー（プロセスが存在しない場合はECHILD）
            return false
        }

        // waitResult == 0 の場合、プロセスはまだ実行中
        // kill(pid, 0) で存在確認
        errno = 0
        let killResult = kill(childPID, 0)
        return killResult == 0
    }

    public func terminate() {
        sendSignalToChild(SIGTERM)

        // Wait briefly for graceful exit
        var status: Int32 = 0
        for _ in 0..<10 {
            let result = waitpid(childPID, &status, WNOHANG)
            if result != 0 {
                return
            }
            usleep(100_000)  // 100ms
        }

        // Fallback to SIGKILL if still running
        sendSignalToChild(SIGKILL)
    }

    public func killProcess() {
        sendSignalToChild(SIGKILL)
    }

    /// 子プロセスにシグナルを送信
    private func sendSignalToChild(_ signal: Int32) {
        let parentPGID = getpgid(getpid())
        var pgids = Set<pid_t>()
        if childPGID > 0 { pgids.insert(childPGID) }
        let currentChildPGID = getpgid(childPID)
        if currentChildPGID > 0 { pgids.insert(currentChildPGID) }
        let foregroundPGID = tcgetpgrp(masterFD)
        if foregroundPGID > 0 { pgids.insert(foregroundPGID) }

        for pgid in pgids where pgid != parentPGID {
            kill(-pgid, signal)
        }

        // 直接子プロセスにもシグナルを送信
        kill(childPID, signal)
    }

    // MARK: - Cleanup

    public func close() {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else { return }
        isClosed = true

        // 1. Send Ctrl+C (ETX) to the PTY to signal interrupt
        let ctrlC = Data([0x03])
        _ = Darwin.write(masterFD, [UInt8](ctrlC), ctrlC.count)

        // 2. Wait briefly for graceful exit
        var status: Int32 = 0
        for _ in 0..<10 {
            let result = waitpid(childPID, &status, WNOHANG)
            if result != 0 {
                Darwin.close(masterFD)
                return
            }
            usleep(100_000)  // 100ms
        }

        // 3. Send SIGINT to process group/child
        sendSignalToChild(SIGINT)

        for _ in 0..<10 {
            let result = waitpid(childPID, &status, WNOHANG)
            if result != 0 {
                Darwin.close(masterFD)
                return
            }
            usleep(100_000)
        }

        // 4. Send SIGTERM
        sendSignalToChild(SIGTERM)

        for _ in 0..<10 {
            let result = waitpid(childPID, &status, WNOHANG)
            if result != 0 {
                Darwin.close(masterFD)
                return
            }
            usleep(100_000)
        }

        // 5. Force kill as last resort
        sendSignalToChild(SIGKILL)
        waitpid(childPID, &status, 0)

        Darwin.close(masterFD)
    }

    deinit {
        close()
    }
}
