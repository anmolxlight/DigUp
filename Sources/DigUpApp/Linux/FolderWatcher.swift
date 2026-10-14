import Foundation
import Glibc

/// What FSEvents does on a Mac, with inotify: reports which paths changed in the chosen folders, a batch at a time
/// (`latency` after the first change), and the engine debounces and syncs. inotify watches one folder at a time, so
/// every folder under the roots gets a watch, and folders that appear later get theirs as they come. Hidden files and
/// folders (editors' temp files, .git) are ignored, as on a Mac.
/// ponytail: one watch per folder, so a tree past fs.inotify.max_user_watches (65k+ on current kernels) is watched in
/// part; past that the engine's next sync (a launch, a drive, a folder change) still catches what changed.
nonisolated final class FolderWatcher: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead
    private let queue: DispatchQueue
    private let latency: TimeInterval
    private let handler: @Sendable ([String]) -> Void
    // queue only
    private var folders: [Int32: String] = [:]
    private var changed: [String] = []
    private var flushScheduled = false

    private static let mask = UInt32(IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO
                                     | IN_DELETE_SELF | IN_ATTRIB)

    init?(paths: [String], latency: TimeInterval, queue: DispatchQueue,
          handler: @escaping @Sendable ([String]) -> Void) {
        guard !paths.isEmpty else { return nil }
        fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else { return nil }
        self.queue = queue
        self.latency = latency
        self.handler = handler
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        for path in paths { watchTree(path) }
        guard !folders.isEmpty else {
            close(fd)
            return nil
        }
        source.setEventHandler { [weak self] in self?.read() }
        source.resume()
    }

    deinit {
        source.cancel()
        close(fd)
    }

    /// `path` and every folder under it, hidden ones and packages' insides aside.
    private func watchTree(_ path: String) {
        watch(path)
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if url.lastPathComponent == "node_modules" {
                walker.skipDescendants()
                continue
            }
            watch(url.path)
        }
    }

    private func watch(_ path: String) {
        let descriptor = inotify_add_watch(fd, path, Self.mask)
        if descriptor >= 0 { folders[descriptor] = path }
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            var offset = 0
            while offset + MemoryLayout<inotify_event>.size <= count {
                let (descriptor, mask, length, name) = buffer.withUnsafeBytes { raw -> (Int32, UInt32, Int, String) in
                    let event = raw.load(fromByteOffset: offset, as: inotify_event.self)
                    let start = offset + MemoryLayout<inotify_event>.size
                    let bytes = raw[start..<(start + Int(event.len))].prefix { $0 != 0 }
                    return (event.wd, event.mask, Int(event.len), String(decoding: bytes, as: UTF8.self))
                }
                offset += MemoryLayout<inotify_event>.size + length
                guard let folder = folders[descriptor] else { continue }
                if mask & UInt32(IN_IGNORED) != 0 {
                    folders[descriptor] = nil
                    continue
                }
                let path = name.isEmpty ? folder : folder + "/" + name
                // A new folder (made, or moved in): watch it and what's already in it.
                if mask & UInt32(IN_ISDIR) != 0, mask & UInt32(IN_CREATE | IN_MOVED_TO) != 0, !name.hasPrefix(".") {
                    watchTree(path)
                }
                changed.append(path)
            }
        }
        guard !changed.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + latency) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        let paths = Array(Set(changed)).filter { path in !path.split(separator: "/").contains { $0.hasPrefix(".") } }
        changed = []
        if !paths.isEmpty { handler(paths) }
    }
}

/// glibc's: hands freed heap pages back to the system (`returnFreedMemory`, which a Mac does with malloc zones).
@_silgen_name("malloc_trim") nonisolated func malloc_trim(_ pad: Int) -> Int32
