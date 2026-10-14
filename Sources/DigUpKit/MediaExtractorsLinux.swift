#if !canImport(AVFoundation)
import Foundation

// AVFoundation's part of the port: ffprobe says how long a file is and what's in it, ffmpeg decodes. The windowing,
// the silence gate, the WAV writer and the shot detection are the shared ones in MediaExtractors.swift, so a Linux
// index holds the same pieces of a file as a Mac's.

/// What ffprobe says about a media file.
struct Probe {
    var duration: Double?
    var hasAudio = false
    var hasVideo = false
}

extension MediaInfo {
    static func probe(_ url: URL) -> Probe {
        var probe = Probe()
        guard let text = try? Tool.text("ffprobe", ["-v", "error", "-show_entries",
                                                    "format=duration:stream=codec_type", "-of", "default=nw=1",
                                                    url.path])
        else { return probe }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch (parts[0], parts[1]) {
            case ("duration", let value): probe.duration = Double(value).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            case ("codec_type", "audio"): probe.hasAudio = true
            case ("codec_type", "video"): probe.hasVideo = true
            default: break
            }
        }
        return probe
    }
}

extension AudioExtractor {
    /// Decodes audio (a file, or a video's soundtrack) to 16 kHz mono with ffmpeg and cuts it into windows the same
    /// way the Mac does (`AudioExtractor.slice`). Streams: memory stays at one window.
    static func windows(of url: URL, window: Double, hop: Double, minimum: Double = 2, to folder: URL) async throws
        -> (pieces: [MediaPiece], duration: Double) {
        let probe = MediaInfo.probe(url)
        guard probe.hasAudio else { return ([], 0) }
        var spare = Data()   // a trailing odd byte: samples straddle the reads
        let sliced = try Tool.stream("ffmpeg", ["-nostdin", "-loglevel", "error", "-i", url.path, "-vn",
                                                "-map", "0:a:0", "-ac", "1", "-ar", "\(Int(sampleRate))",
                                                "-f", "s16le", "-acodec", "pcm_s16le", "-"]) { read in
            try slice(window: window, hop: hop, minimum: minimum, to: folder) {
                guard var chunk = try read() else { return nil }
                if !spare.isEmpty { chunk = spare + chunk; spare = Data() }
                if chunk.count % 2 == 1 { spare = chunk.suffix(1); chunk = chunk.dropLast() }
                return chunk.withUnsafeBytes { bytes in
                    Array(UnsafeRawBufferPointer(bytes).bindMemory(to: Int16.self))
                }
            }
        }
        return (sliced.pieces, probe.duration ?? Double(sliced.samples) / sampleRate)
    }
}

extension VideoExtractor {
    /// Samples a frame every `interval` seconds and keeps one per shot, exactly as the Mac does: ffmpeg's `select`
    /// filter picks the frames (keeping their own timestamps: `fps` would report them on its grid, half a second
    /// before the frame it took), `showinfo` reports the time each one really sits at, and a second branch of the
    /// same pass writes each frame as 8×8 grey so the average hashes cost no extra decoding.
    static func keyframes(of url: URL, every interval: Double, maxPixel: Int, maxFrames: Int = 1200, to folder: URL)
        async throws -> (frames: [MediaPiece], duration: Double, hasAudio: Bool) {
        let probe = MediaInfo.probe(url)
        let hasAudio = probe.hasAudio
        guard let duration = probe.duration, duration > 0, probe.hasVideo else { return ([], probe.duration ?? 0, hasAudio) }

        let step = max(interval, duration / Double(maxFrames))
        let start = min(0.5, duration / 2)
        let sampled = folder.appendingPathComponent("frames-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sampled, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sampled) }
        let hashes = sampled.appendingPathComponent("hashes.gray")
        let filter = """
            [0:v]select='isnan(prev_selected_t)*gte(t,\(start))+gte(t-prev_selected_t,\(step))',showinfo,\
            split=2[full][tiny];\
            [full]scale=w='min(\(maxPixel),iw)':h='min(\(maxPixel),ih)':force_original_aspect_ratio=decrease[out];\
            [tiny]scale=8:8,format=gray[hash]
            """
        let log = try Tool.diagnostics("ffmpeg", ["-nostdin", "-loglevel", "info", "-y", "-i", url.path,
                                                  "-filter_complex", filter,
                                                  "-map", "[out]", "-qscale:v", "3", "-vsync", "0",
                                                  sampled.path + "/%06d.jpg",
                                                  "-map", "[hash]", "-f", "rawvideo", "-pix_fmt", "gray",
                                                  hashes.path])
        // showinfo writes one "pts_time:<seconds>" a frame, in order.
        var times: [Double] = []
        for line in log.split(separator: "\n") where line.contains("pts_time:") {
            guard let range = line.range(of: "pts_time:") else { continue }
            let rest = line[range.upperBound...].prefix { !$0.isWhitespace }
            if let seconds = Double(rest) { times.append(seconds) }
        }
        let grey = (try? Data(contentsOf: hashes)) ?? Data()
        var frames: [MediaPiece] = []
        var lastHash: UInt64?
        var kept = 0
        for index in 0..<times.count {
            let file = sampled.appendingPathComponent(String(format: "%06d.jpg", index + 1))
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let at = index * 64
            guard at + 64 <= grey.count else { continue }
            let hash = averageHash([UInt8](grey[(grey.startIndex + at)..<(grey.startIndex + at + 64)]))
            if let lastHash, (hash ^ lastHash).nonzeroBitCount <= 4 { continue }
            lastHash = hash
            kept += 1
            let out = folder.appendingPathComponent(UUID().uuidString + ".jpg")
            try FileManager.default.moveItem(at: file, to: out)
            frames.append(MediaPiece(path: out.path, start: max(0, times[index]), end: duration))
        }
        _ = kept
        // Each kept frame stands for the stretch until the next kept frame.
        for index in frames.indices.dropLast() { frames[index].end = frames[index + 1].start }
        return (frames, duration, hasAudio)
    }
}
#endif
