import Foundation

/// Where DigUp keeps its things. The Mac uses Application Support; Linux follows the XDG base directory spec.
public enum AppPaths {
    /// The model, the indexes and the app's own state.
    public static var support: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DigUp")
        #else
        xdg("XDG_DATA_HOME", ".local/share").appendingPathComponent("DigUp")
        #endif
    }

    /// Settings. On a Mac they're in the user defaults plist, which `AppSettings` writes; on Linux it's a file here.
    public static var config: URL {
        #if os(macOS)
        support
        #else
        xdg("XDG_CONFIG_HOME", ".config").appendingPathComponent("DigUp")
        #endif
    }

    /// `~/Library/Application Support/DigUp/…` on a Mac, `~/.local/share/DigUp/…` on Linux: the string the CLI's
    /// help and its `--index` default show.
    public static var supportHint: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = support.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    #if !os(macOS)
    private static func xdg(_ variable: String, _ fallback: String) -> URL {
        if let set = ProcessInfo.processInfo.environment[variable], set.hasPrefix("/") {
            return URL(fileURLWithPath: set)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback)
    }
    #endif
}

/// Running a command-line tool and collecting its output. On Linux the readers that are Apple frameworks on a Mac
/// (ImageIO, PDFKit, Vision, AVFoundation) are command-line tools instead, so this carries the port.
enum Tool {
    struct Failure: Error, CustomStringConvertible {
        let tool: String
        let status: Int32
        let message: String
        var description: String { message.isEmpty ? "\(tool) failed (\(status))" : "\(tool): \(message)" }
    }

    /// The first of `names` on PATH (or at an absolute path), remembered.
    static func find(_ names: String...) -> String? {
        for name in names {
            if name.hasPrefix("/") {
                if FileManager.default.isExecutableFile(atPath: name) { return name }
                continue
            }
            for folder in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin")
                .split(separator: ":") {
                let path = folder + "/" + name
                if FileManager.default.isExecutableFile(atPath: String(path)) { return String(path) }
            }
        }
        return nil
    }

    /// Runs `tool` and returns what it wrote to stdout. `stderr` is kept for the error message only.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], stdin: Data? = nil, limit: Int = 1 << 28) throws -> Data {
        guard let executable = find(tool) else { throw Failure(tool: tool, status: -1, message: "\(tool) is not installed") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), error = Pipe()
        process.standardOutput = out
        process.standardError = error
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        // stderr is drained on a thread: a tool that fills its error pipe would otherwise block forever.
        let collected = Collector()
        let draining = Thread { collected.set(error.fileHandleForReading.readDataToEndOfFile()) }
        draining.start()
        var data = Data()
        while let chunk = try out.fileHandleForReading.read(upToCount: 1 << 20), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit { break }
        }
        process.waitUntilExit()
        while !collected.done { usleep(200) }
        guard process.terminationStatus == 0 else {
            let message = String(data: collected.data.suffix(400), encoding: .utf8) ?? ""
            throw Failure(tool: (tool as NSString).lastPathComponent, status: process.terminationStatus,
                          message: message.split(separator: "\n").suffix(2).joined(separator: "; "))
        }
        return data
    }

    /// The tool's stdout as text, trimmed.
    static func text(_ tool: String, _ arguments: [String]) throws -> String {
        String(decoding: try run(tool, arguments), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the tool wrote to stderr (ffmpeg's `showinfo` reports frame times there).
    static func diagnostics(_ tool: String, _ arguments: [String]) throws -> String {
        guard let executable = find(tool) else { throw Failure(tool: tool, status: -1, message: "\(tool) is not installed") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let error = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure(tool: tool, status: process.terminationStatus,
                          message: message.split(separator: "\n").suffix(2).joined(separator: "; "))
        }
        return message
    }

    /// Starts `tool` and hands its stdout over in pieces, so a long decode never has to fit in memory.
    /// `body` gets a reader that returns nil at the end; the process is waited for afterwards.
    static func stream<T>(_ tool: String, _ arguments: [String], _ body: (() throws -> Data?) throws -> T) throws -> T {
        guard let executable = find(tool) else { throw Failure(tool: tool, status: -1, message: "\(tool) is not installed") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            try? out.fileHandleForReading.close()
            process.waitUntilExit()
        }
        let result = try body {
            let chunk = try out.fileHandleForReading.read(upToCount: 1 << 20)
            return (chunk?.isEmpty ?? true) ? nil : chunk
        }
        return result
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        private var finished = false
        func set(_ data: Data) { lock.lock(); value = data; finished = true; lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return value }
        var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    }
}

#if !canImport(ObjectiveC)
/// Linux Foundation has no autorelease pool; the calls that drain one on a Mac are plain calls here.
@inline(__always) func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }
#endif

/// The few file facts whose API differs between the platforms.
enum Files {
    /// Whether the path is a folder, or nil when there's nothing there (`ObjCBool` is Darwin-only).
    static func isFolder(_ path: String) -> Bool? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// A file's modification time, seconds since 1970, to the nanosecond.
    static func modified(_ info: stat) -> Double {
        #if os(macOS)
        Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        #else
        Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1e9
        #endif
    }

    /// Whether this is an app or a document bundle (a folder the Finder shows as one file). Linux has none.
    static func isPackage(_ values: URLResourceValues?) -> Bool {
        #if os(macOS)
        values?.isPackage == true
        #else
        false
        #endif
    }

    /// What kind of file this is: the system's answer on a Mac, the extension tables on Linux (`UTType`).
    static func contentType(of url: URL, _ values: URLResourceValues?) -> UTType? {
        #if os(macOS)
        values?.contentType
        #else
        UTType(filenameExtension: url.pathExtension)
        #endif
    }
}
