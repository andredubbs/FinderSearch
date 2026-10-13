import Foundation
import Darwin

struct Hit: Decodable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let kind: String
    let size: UInt64
    let mtime: UInt64
    let score: Int64
    var metadataPending: Bool? = nil
    var url: URL { URL(fileURLWithPath: path, isDirectory: kind == "dir") }
    var name: String { (path as NSString).lastPathComponent }
    var imageKey: String { path + ":" + String(mtime) + ":" + String(metadataPending == true) }
    var parent: String {
        (path as NSString).deletingLastPathComponent.replacingOccurrences(
            of: NSHomeDirectory(), with: "~", options: .anchored)
    }
}
struct Reply: Decodable {
    let ok: Bool
    let error: String?
    let hits: [Hit]?
    let took_us: UInt64?
    let entries: Int?
    let full_disk_access: Bool?
}

/// One matched line in a file a content search returned. `ranges` are byte
/// offsets into `text` (the line's first 400 bytes); `before`/`after` are
/// the context lines a `context`, `before` or `after` request field asked
/// for. `def` marks a definition match (`sym:` or `defs`).
struct GrepMatch: Decodable, Hashable {
    let line: Int
    let text: String
    let col: Int
    let ranges: [[Int]]
    var def: Bool? = nil
    var before: [String]? = nil
    var after: [String]? = nil
}
/// A file holding at least one matched line.
struct GrepFile: Decodable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let matches: [GrepMatch]
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
    var parent: String {
        (path as NSString).deletingLastPathComponent.replacingOccurrences(
            of: NSHomeDirectory(), with: "~", options: .anchored)
    }
}
/// The reply to an `{"op": "grep"}` request or a query carrying a
/// `grep:`/`regex:`/`sym:`/`content:`/`symbol:` term.
struct GrepReply: Decodable {
    let ok: Bool
    let error: String?
    let files: [GrepFile]?
    let took_us: UInt64?
    /// Where the matches came from: the content index, a live scan, or one
    /// named file.
    let source: String?
    let candidates: Int?
    let read: Int?
    /// False when the time budget ran out before every candidate was read.
    let complete: Bool?
    /// How much of the content index was still being built.
    let indexing: Int?
    /// Where the next page starts, when there may be more files.
    let next: Int?
}

protocol SearchService: Sendable {
    func request(_ fields: [String: Any]) async throws -> Reply
    func grep(_ fields: [String: Any]) async throws -> GrepReply
}

/// A single warm stdio client. Blocking I/O stays on its own serial queue.
final class Engine: SearchService, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FinderSearch.engine", qos: .userInitiated)
    private let binaryOverride: String?
    init(binary: String? = nil) { binaryOverride = binary }
    private var connectedBinary: String?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let message) = self { return message }; return nil
        }
    }
    private func connect() throws {
        if process?.isRunning == true { return }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/fsearch").path
        let candidates = [
            binaryOverride ?? "", bundled,
            ProcessInfo.processInfo.environment["FSEARCH_BINARY"] ?? "",
            NSHomeDirectory() + "/.local/bin/fsearch",
            FileManager.default.currentDirectoryPath + "/vendor/fsearch/target/release/fsearch",
        ]
        guard
            let binary = candidates.first(where: {
                !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0)
            })
        else {
            throw Failure.message("Search engine missing. Run scripts/build.sh to bundle fsearch.")
        }
        // Upstream stdio reuses any running daemon, even after its executable
        // was replaced. Restart our own outdated helper before connecting.
        if let modified = try URL(fileURLWithPath: binary).resourceValues(
            forKeys: [.contentModificationDateKey]).contentModificationDate
        {
            _ = try RestrictedDaemon.recover(binary: binary, ifStartedBefore: modified)
        }
        // A restarted shared daemon can close another tab's helper pipe.
        // Surface a write failure instead of terminating the app.
        signal(SIGPIPE, SIG_IGN)
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["stdio"]
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        try p.run()
        connectedBinary = binary
        process = p; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        buffer.removeAll()
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value { throw CancellationError() }
        }
    }
    /// One request's reply line. Runs on `queue`; the daemon answers each
    /// request with exactly one line of JSON.
    private func exchange(_ fields: [String: Any], cancellation: Cancellation) throws -> Data {
        try cancellation.check()
        try connect()
        let data = try JSONSerialization.data(withJSONObject: fields)
        try input?.write(contentsOf: data + Data([10]))
        guard let output else {
            throw Failure.message("Engine disconnected.")
        }
        let deadline = Date().addingTimeInterval(15)
        while !buffer.contains(10) {
            try cancellation.check()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw Failure.message("Search engine timed out. Try again.")
            }
            var fd = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&fd, 1, Int32(min(remaining, 0.1) * 1000))
            if result == 0 { continue }
            guard result > 0 else {
                throw Failure.message("Search engine timed out. Try again.")
            }
            let chunk = output.availableData
            guard !chunk.isEmpty else {
                throw Failure.message("Search engine stopped. Try again.")
            }
            buffer.append(chunk)
        }
        try cancellation.check()
        let newline = buffer.firstIndex(of: 10)!
        let line = buffer.prefix(upTo: newline)
        buffer.removeSubrange(...newline)
        return Data(line)
    }
    private func call<T: Decodable>(
        _ fields: [String: Any], as type: T.Type,
        retry: ((T) throws -> Bool)? = nil
    ) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        for _ in 0..<2 {
                            let reply = try JSONDecoder().decode(
                                T.self,
                                from: try self.exchange(fields, cancellation: cancellation))
                            let again = try retry?(reply) ?? false
                            if again {
                                self.disconnect()
                                continue
                            }
                            continuation.resume(returning: reply)
                            return
                        }
                        continuation.resume(
                            throwing: Failure.message("Search engine stopped. Try again."))
                    } catch {
                        self.disconnect()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
    func request(_ fields: [String: Any]) async throws -> Reply {
        var attempt = 0
        return try await call(fields, as: Reply.self) { reply in
            defer { attempt += 1 }
            if attempt == 0, fields["op"] as? String == "status",
                reply.full_disk_access == false, FullDiskAccess.isGranted(),
                let binary = self.connectedBinary,
                try RestrictedDaemon.recover(binary: binary)
            {
                return true
            }
            return false
        }
    }
    func grep(_ fields: [String: Any]) async throws -> GrepReply {
        try await call(fields, as: GrepReply.self)
    }
    private func disconnect() {
        process?.terminate(); process = nil
        input = nil; output = nil; buffer.removeAll()
    }
    deinit { process?.terminate() }
}
