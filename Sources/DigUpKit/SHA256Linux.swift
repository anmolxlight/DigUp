#if !canImport(CryptoKit)
import Foundation

/// SHA-256 (FIPS 180-4), the few lines CryptoKit stands in for on a Mac: `ModelFiles.sha256` checks a downloaded
/// model file with it. Same shape as `CryptoKit.SHA256`, so the call site is unchanged. ~200 MB/s on this machine,
/// fast enough for the one 555 MB file it ever reads.
struct SHA256 {
    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var tail = [UInt8]()     // bytes not yet in a full 64-byte block
    private var length: UInt64 = 0   // bytes hashed, for the padding

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    init() {}

    mutating func update(data: Data) {
        length &+= UInt64(data.count)
        var bytes = data
        if !tail.isEmpty {
            let want = min(64 - tail.count, bytes.count)
            tail.append(contentsOf: bytes.prefix(want))
            bytes = bytes.dropFirst(want)
            guard tail.count == 64 else { return }
            tail.withUnsafeBufferPointer { block($0.baseAddress!) }
            tail.removeAll(keepingCapacity: true)
        }
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while buffer.count - offset >= 64 {
                block(base + offset)
                offset += 64
            }
            tail.append(contentsOf: UnsafeBufferPointer(start: base + offset, count: buffer.count - offset))
        }
    }

    mutating func finalize() -> [UInt8] {
        let bits = length &* 8
        var padding: [UInt8] = [0x80]
        padding.append(contentsOf: [UInt8](repeating: 0, count: (56 &- (Int(length) &+ 1) % 64 &+ 64) % 64))
        padding.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: bits >> (56 - 8 * $0)) })
        let kept = length
        update(data: Data(padding))
        length = kept
        return state.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (24 - 8 * $0)) } }
    }

    private mutating func block(_ bytes: UnsafePointer<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = UInt32(bytes[i * 4]) << 24 | UInt32(bytes[i * 4 + 1]) << 16
                 | UInt32(bytes[i * 4 + 2]) << 8 | UInt32(bytes[i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, b, c, d) = (state[0], state[1], state[2], state[3])
        var (e, f, g, h) = (state[4], state[5], state[6], state[7])
        for i in 0..<64 {
            let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            (h, g, f, e) = (g, f, e, d &+ t1)
            (d, c, b, a) = (c, b, a, t1 &+ t2)
        }
        for (index, value) in [a, b, c, d, e, f, g, h].enumerated() { state[index] = state[index] &+ value }
    }

    private func rotate(_ value: UInt32, _ by: UInt32) -> UInt32 { (value >> by) | (value << (32 - by)) }
}
#endif

#if !canImport(CryptoKit)
extension SHA256 {
    /// One-shot, like `CryptoKit.SHA256.hash(data:)`.
    static func hash(data: Data) -> [UInt8] {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize()
    }
}
#endif
