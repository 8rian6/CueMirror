import Foundation

struct AudioCueLocation: Equatable {
    /// 包含 Cue 的解码块首样本位置。
    var decodingStartFramePosition: UInt64
    /// FLAC 首个音频 frame 到目标 frame 的字节距离。
    var fileOffsetInBlock: UInt64
    /// 目标 FLAC frame 包含的样本数。
    var numberOfSamplesInBlock: UInt32
    var targetSamplePosition: UInt64
    var frameEndSamplePosition: UInt64
    var absoluteFileOffset: UInt64
    var audioStreamOffset: UInt64
    var usesVariableBlockStrategy: Bool
}

protocol AudioCueLocating {
    func locateCue(atMilliseconds timeMs: UInt64, in audioFile: URL) throws -> AudioCueLocation
}

enum AudioCueLocatorError: LocalizedError, Equatable {
    case unsupportedFile
    case truncated(offset: Int)
    case missingStreamInfo
    case invalidStreamInfo
    case frameNotFound(targetSample: UInt64)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: return L("目前只支持原生 FLAC。")
        case .truncated(let offset): return LF("FLAC 在偏移 %llu 处截断。", offset)
        case .missingStreamInfo: return L("FLAC 缺少 STREAMINFO。")
        case .invalidStreamInfo: return L("FLAC STREAMINFO 无效。")
        case .frameNotFound(let sample): return LF("找不到包含样本 %llu 的 FLAC frame。", sample)
        }
    }
}

/// FLAC 专用实现。其他编码格式必须提供各自独立的 locator。
struct FLACAudioCueLocator: AudioCueLocating {
    func locateCue(atMilliseconds timeMs: UInt64, in audioFile: URL) throws -> AudioCueLocation {
        let data = try Data(contentsOf: audioFile, options: .mappedIfSafe)
        let stream = try parseMetadata(data)
        let target = timeMs.multipliedReportingOverflow(by: UInt64(stream.sampleRate))
        guard !target.overflow else { throw AudioCueLocatorError.invalidStreamInfo }
        let targetSample = target.partialValue / 1_000

        let seekPoint = stream.seekPoints.last(where: {
            $0.sampleNumber <= targetSample && $0.sampleNumber != UInt64.max
        })
        var cursor = stream.audioOffset + Int(seekPoint?.streamOffset ?? 0)

        while cursor + 6 < data.count {
            guard data[cursor] == 0xff, data[cursor + 1] & 0xfe == 0xf8 else {
                cursor += 1
                continue
            }
            guard let frame = parseFrameHeader(data, at: cursor, stream: stream) else {
                cursor += 1
                continue
            }
            let frameEnd = frame.firstSample + UInt64(frame.blockSize)
            if targetSample >= frame.firstSample, targetSample < frameEnd {
                return AudioCueLocation(
                    decodingStartFramePosition: frame.firstSample,
                    fileOffsetInBlock: UInt64(cursor - stream.audioOffset),
                    numberOfSamplesInBlock: frame.blockSize,
                    targetSamplePosition: targetSample,
                    frameEndSamplePosition: frameEnd,
                    absoluteFileOffset: UInt64(cursor),
                    audioStreamOffset: UInt64(stream.audioOffset),
                    usesVariableBlockStrategy: frame.variableBlock
                )
            }
            if frame.firstSample > targetSample { break }
            cursor += 1
        }
        throw AudioCueLocatorError.frameNotFound(targetSample: targetSample)
    }

    private struct Stream {
        var minimumBlockSize: UInt32
        var maximumBlockSize: UInt32
        var sampleRate: UInt32
        var audioOffset: Int
        var seekPoints: [SeekPoint]
    }

    private struct SeekPoint {
        var sampleNumber: UInt64
        var streamOffset: UInt64
    }

    private struct Frame {
        var firstSample: UInt64
        var blockSize: UInt32
        var variableBlock: Bool
    }

    private func parseMetadata(_ data: Data) throws -> Stream {
        guard data.count >= 8, data.prefix(4) == Data("fLaC".utf8) else {
            throw AudioCueLocatorError.unsupportedFile
        }
        var cursor = 4
        var minimumBlockSize: UInt32?
        var maximumBlockSize: UInt32?
        var sampleRate: UInt32?
        var seekPoints: [SeekPoint] = []
        var isLast = false

        while !isLast {
            guard cursor + 4 <= data.count else { throw AudioCueLocatorError.truncated(offset: cursor) }
            let first = data[cursor]
            isLast = first & 0x80 != 0
            let type = first & 0x7f
            let length = Int(data[cursor + 1]) << 16 | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
            let payload = cursor + 4
            let end = payload + length
            guard end <= data.count else { throw AudioCueLocatorError.truncated(offset: cursor) }

            if type == 0 {
                guard length == 34 else { throw AudioCueLocatorError.invalidStreamInfo }
                minimumBlockSize = UInt32(data.u16BE(payload))
                maximumBlockSize = UInt32(data.u16BE(payload + 2))
                sampleRate = UInt32(data[payload + 10]) << 12 |
                    UInt32(data[payload + 11]) << 4 |
                    UInt32(data[payload + 12] >> 4)
            } else if type == 3 {
                var point = payload
                while point + 18 <= end {
                    seekPoints.append(SeekPoint(
                        sampleNumber: data.u64BE(point),
                        streamOffset: data.u64BE(point + 8)
                    ))
                    point += 18
                }
            }
            cursor = end
        }

        guard let minimumBlockSize, let maximumBlockSize, let sampleRate else {
            throw AudioCueLocatorError.missingStreamInfo
        }
        guard minimumBlockSize > 0, maximumBlockSize >= minimumBlockSize, sampleRate > 0 else {
            throw AudioCueLocatorError.invalidStreamInfo
        }
        return Stream(
            minimumBlockSize: minimumBlockSize,
            maximumBlockSize: maximumBlockSize,
            sampleRate: sampleRate,
            audioOffset: cursor,
            seekPoints: seekPoints.sorted { $0.sampleNumber < $1.sampleNumber }
        )
    }

    private func parseFrameHeader(_ data: Data, at offset: Int, stream: Stream) -> Frame? {
        guard offset + 6 < data.count else { return nil }
        let variableBlock = data[offset + 1] & 0x01 != 0
        let blockCode = data[offset + 2] >> 4
        let sampleRateCode = data[offset + 2] & 0x0f
        let reserved = data[offset + 3] & 0x01
        guard blockCode != 0, sampleRateCode != 0x0f, reserved == 0 else { return nil }

        var cursor = offset + 4
        guard let codedNumber = readUTF8Integer(data, cursor: &cursor) else { return nil }
        guard let blockSize = readBlockSize(code: blockCode, data: data, cursor: &cursor) else { return nil }
        guard skipExplicitSampleRate(code: sampleRateCode, data: data, cursor: &cursor) else { return nil }
        guard cursor < data.count else { return nil }

        let storedCRC = data[cursor]
        guard crc8(data[offset..<cursor]) == storedCRC else { return nil }
        let firstSample: UInt64
        if variableBlock {
            firstSample = codedNumber
        } else {
            let multiplication = codedNumber.multipliedReportingOverflow(by: UInt64(blockSize))
            guard !multiplication.overflow else { return nil }
            firstSample = multiplication.partialValue
        }
        return Frame(firstSample: firstSample, blockSize: blockSize, variableBlock: variableBlock)
    }

    private func readUTF8Integer(_ data: Data, cursor: inout Int) -> UInt64? {
        guard cursor < data.count else { return nil }
        let first = data[cursor]
        cursor += 1
        if first & 0x80 == 0 { return UInt64(first) }
        let leading = first.leadingZeroBitCount
        let count = leading == 0 ? first.leadingOneCount : 0
        guard (2...7).contains(count), cursor + count - 1 <= data.count else { return nil }
        var value = UInt64(first & UInt8(0x7f >> count))
        for _ in 1..<count {
            guard cursor < data.count, data[cursor] & 0xc0 == 0x80 else { return nil }
            value = value << 6 | UInt64(data[cursor] & 0x3f)
            cursor += 1
        }
        return value
    }

    private func readBlockSize(code: UInt8, data: Data, cursor: inout Int) -> UInt32? {
        switch code {
        case 1: return 192
        case 2...5: return 576 << UInt32(code - 2)
        case 6:
            guard cursor < data.count else { return nil }
            defer { cursor += 1 }
            return UInt32(data[cursor]) + 1
        case 7:
            guard cursor + 2 <= data.count else { return nil }
            defer { cursor += 2 }
            return UInt32(data.u16BE(cursor)) + 1
        case 8...15: return 256 << UInt32(code - 8)
        default: return nil
        }
    }

    private func skipExplicitSampleRate(code: UInt8, data: Data, cursor: inout Int) -> Bool {
        let byteCount: Int
        switch code {
        case 12: byteCount = 1
        case 13, 14: byteCount = 2
        default: byteCount = 0
        }
        guard cursor + byteCount <= data.count else { return false }
        cursor += byteCount
        return true
    }

    private func crc8(_ bytes: Data.SubSequence) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }
}

private extension UInt8 {
    var leadingOneCount: Int {
        var mask: UInt8 = 0x80
        var result = 0
        while self & mask != 0 { result += 1; mask >>= 1 }
        return result
    }
}

private extension Data {
    func u16BE(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func u64BE(_ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<offset + 8 { value = value << 8 | UInt64(self[index]) }
        return value
    }
}
