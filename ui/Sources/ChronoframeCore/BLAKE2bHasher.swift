import Foundation

public struct BLAKE2bHasher: Sendable {
    public static let digestByteCount = 64
    public static let blockByteCount = 128

    private var state = Self.initialState
    private var counterLow: UInt64 = 0
    private var counterHigh: UInt64 = 0
    private var finalizationFlag: UInt64 = 0
    private var buffer = [UInt8](repeating: 0, count: blockByteCount)
    private var bufferedByteCount = 0

    public init() {
        state[0] ^= 0x0101_0040
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            update(rawBuffer)
        }
    }

    public mutating func update(_ rawBuffer: UnsafeRawBufferPointer) {
        guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return
        }

        var index = 0
        let inputCount = rawBuffer.count

        if bufferedByteCount > 0 {
            let bytesNeeded = Self.blockByteCount - bufferedByteCount
            let prefixCount = min(bytesNeeded, inputCount)
            buffer.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.advanced(by: bufferedByteCount)
                    .update(from: baseAddress, count: prefixCount)
            }
            bufferedByteCount += prefixCount
            index += prefixCount

            if bufferedByteCount == Self.blockByteCount {
                incrementCounter(by: UInt64(Self.blockByteCount))
                compress(block: buffer)
                bufferedByteCount = 0
            }
        }

        while index + Self.blockByteCount < inputCount {
            incrementCounter(by: UInt64(Self.blockByteCount))
            compress(block: UnsafeRawBufferPointer(start: baseAddress.advanced(by: index), count: Self.blockByteCount))
            index += Self.blockByteCount
        }

        let remainingCount = inputCount - index
        guard remainingCount > 0 else {
            return
        }

        buffer.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.update(from: baseAddress.advanced(by: index), count: remainingCount)
        }
        bufferedByteCount = remainingCount
    }

    public mutating func finalize() -> [UInt8] {
        incrementCounter(by: UInt64(bufferedByteCount))
        finalizationFlag = .max

        if bufferedByteCount < Self.blockByteCount {
            buffer.replaceSubrange(
                bufferedByteCount..<Self.blockByteCount,
                with: repeatElement(0, count: Self.blockByteCount - bufferedByteCount)
            )
        }

        compress(block: buffer)

        var digest = [UInt8]()
        digest.reserveCapacity(Self.digestByteCount)
        for value in state {
            digest.append(UInt8(truncatingIfNeeded: value))
            digest.append(UInt8(truncatingIfNeeded: value >> 8))
            digest.append(UInt8(truncatingIfNeeded: value >> 16))
            digest.append(UInt8(truncatingIfNeeded: value >> 24))
            digest.append(UInt8(truncatingIfNeeded: value >> 32))
            digest.append(UInt8(truncatingIfNeeded: value >> 40))
            digest.append(UInt8(truncatingIfNeeded: value >> 48))
            digest.append(UInt8(truncatingIfNeeded: value >> 56))
        }
        return Array(digest.prefix(Self.digestByteCount))
    }

    public mutating func finalizeHexDigest() -> String {
        Self.hexString(for: finalize())
    }

    public static func hashHex(of data: Data) -> String {
        var hasher = Self()
        hasher.update(data)
        return hasher.finalizeHexDigest()
    }

    private mutating func incrementCounter(by amount: UInt64) {
        let newLow = counterLow &+ amount
        if newLow < counterLow {
            counterHigh &+= 1
        }
        counterLow = newLow
    }

    private mutating func compress(block: [UInt8]) {
        block.withUnsafeBytes { rawBuffer in
            compress(block: rawBuffer)
        }
    }

    private mutating func compress(block: UnsafeRawBufferPointer) {
        var message = [UInt64](repeating: 0, count: 16)
        for index in 0..<16 {
            message[index] = Self.loadLittleEndian64(from: block, at: index * 8)
        }

        var workingVector = [UInt64](repeating: 0, count: 16)
        for index in 0..<8 {
            workingVector[index] = state[index]
            workingVector[index + 8] = Self.initialState[index]
        }

        workingVector[12] ^= counterLow
        workingVector[13] ^= counterHigh
        workingVector[14] ^= finalizationFlag

        for round in 0..<Self.sigma.count {
            let schedule = Self.sigma[round]
            Self.mix(&workingVector, 0, 4, 8, 12, message[schedule[0]], message[schedule[1]])
            Self.mix(&workingVector, 1, 5, 9, 13, message[schedule[2]], message[schedule[3]])
            Self.mix(&workingVector, 2, 6, 10, 14, message[schedule[4]], message[schedule[5]])
            Self.mix(&workingVector, 3, 7, 11, 15, message[schedule[6]], message[schedule[7]])
            Self.mix(&workingVector, 0, 5, 10, 15, message[schedule[8]], message[schedule[9]])
            Self.mix(&workingVector, 1, 6, 11, 12, message[schedule[10]], message[schedule[11]])
            Self.mix(&workingVector, 2, 7, 8, 13, message[schedule[12]], message[schedule[13]])
            Self.mix(&workingVector, 3, 4, 9, 14, message[schedule[14]], message[schedule[15]])
        }

        for index in 0..<8 {
            state[index] ^= workingVector[index] ^ workingVector[index + 8]
        }
    }

    private static func mix(
        _ vector: inout [UInt64],
        _ a: Int,
        _ b: Int,
        _ c: Int,
        _ d: Int,
        _ x: UInt64,
        _ y: UInt64
    ) {
        vector[a] = vector[a] &+ vector[b] &+ x
        vector[d] = rotateRight(vector[d] ^ vector[a], by: 32)
        vector[c] = vector[c] &+ vector[d]
        vector[b] = rotateRight(vector[b] ^ vector[c], by: 24)
        vector[a] = vector[a] &+ vector[b] &+ y
        vector[d] = rotateRight(vector[d] ^ vector[a], by: 16)
        vector[c] = vector[c] &+ vector[d]
        vector[b] = rotateRight(vector[b] ^ vector[c], by: 63)
    }

    private static func rotateRight(_ value: UInt64, by count: UInt64) -> UInt64 {
        (value >> count) | (value << (64 - count))
    }

    private static func loadLittleEndian64(from rawBuffer: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        return UInt64(bytes[offset])
            | (UInt64(bytes[offset + 1]) << 8)
            | (UInt64(bytes[offset + 2]) << 16)
            | (UInt64(bytes[offset + 3]) << 24)
            | (UInt64(bytes[offset + 4]) << 32)
            | (UInt64(bytes[offset + 5]) << 40)
            | (UInt64(bytes[offset + 6]) << 48)
            | (UInt64(bytes[offset + 7]) << 56)
    }

    private static func hexString(for bytes: [UInt8]) -> String {
        let hexDigits = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        result.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            result.append(hexDigits[Int(byte >> 4)])
            result.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static let initialState: [UInt64] = [
        0x6A09E667F3BCC908,
        0xBB67AE8584CAA73B,
        0x3C6EF372FE94F82B,
        0xA54FF53A5F1D36F1,
        0x510E527FADE682D1,
        0x9B05688C2B3E6C1F,
        0x1F83D9ABFB41BD6B,
        0x5BE0CD19137E2179,
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    ]
}
