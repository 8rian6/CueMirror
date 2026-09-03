import AudioToolbox
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
    case systemAudioError(Int32)
    case invalidPacketInfo
    case unsupportedExperimentalFile
    case experimentalFrameNotFound(targetSample: UInt64)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: return L("文件扩展名是 FLAC，但未找到可识别的 FLAC 音频流。")
        case .truncated(let offset): return LF("FLAC 在偏移 %llu 处截断。", offset)
        case .missingStreamInfo: return L("FLAC 缺少 STREAMINFO。")
        case .invalidStreamInfo: return L("FLAC STREAMINFO 无效。")
        case .frameNotFound(let sample): return LF("找不到包含样本 %llu 的 FLAC frame。", sample)
        case .systemAudioError(let status): return LF("系统音频解析失败（错误码 %d）。", status)
        case .invalidPacketInfo: return L("无法取得目标音频数据包的定位信息。")
        case .unsupportedExperimentalFile: return L("无法解析该音频文件。")
        case .experimentalFrameNotFound(let sample): return LF("找不到包含样本 %llu 的音频帧。", sample)
        }
    }
}

/// 通用定位器。使用 macOS AudioToolbox 获取 WAV/AIFF 的真实数据包位置，
/// 与已经验证的 FLAC 定位器完全隔离。
struct SystemAudioCueLocator: AudioCueLocating {
    func locateCue(atMilliseconds timeMs: UInt64, in audioFile: URL) throws -> AudioCueLocation {
        var audioFileID: AudioFileID?
        let openStatus = AudioFileOpenURL(audioFile as CFURL, .readPermission, 0, &audioFileID)
        guard openStatus == noErr, let audioFileID else {
            throw AudioCueLocatorError.systemAudioError(openStatus)
        }
        defer { AudioFileClose(audioFileID) }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioFileGetProperty(
            audioFileID, kAudioFilePropertyDataFormat, &formatSize, &format
        )
        guard formatStatus == noErr, format.mSampleRate > 0 else {
            throw AudioCueLocatorError.systemAudioError(formatStatus)
        }

        var packetCount: Int64 = 0
        var packetCountSize = UInt32(MemoryLayout<Int64>.size)
        let countStatus = AudioFileGetProperty(
            audioFileID, kAudioFilePropertyAudioDataPacketCount, &packetCountSize, &packetCount
        )
        guard countStatus == noErr, packetCount > 0 else {
            throw AudioCueLocatorError.systemAudioError(countStatus)
        }

        let targetSample = UInt64((Double(timeMs) * format.mSampleRate / 1_000).rounded(.down))
        var frameTranslation = AudioFramePacketTranslation(
            mFrame: Int64(targetSample), mPacket: 0, mFrameOffsetInPacket: 0
        )
        var frameTranslationSize = UInt32(MemoryLayout<AudioFramePacketTranslation>.size)
        let frameStatus = AudioFileGetProperty(
            audioFileID, kAudioFilePropertyFrameToPacket,
            &frameTranslationSize, &frameTranslation
        )
        guard frameStatus == noErr, frameTranslation.mPacket >= 0 else {
            throw AudioCueLocatorError.systemAudioError(frameStatus)
        }
        let targetPacket = min(frameTranslation.mPacket, packetCount - 1)
        var translation = AudioBytePacketTranslation(
            mByte: 0,
            mPacket: targetPacket,
            mByteOffsetInPacket: 0,
            mFlags: []
        )
        var translationSize = UInt32(MemoryLayout<AudioBytePacketTranslation>.size)
        let packetStatus = AudioFileGetProperty(
            audioFileID, kAudioFilePropertyPacketToByte, &translationSize, &translation
        )
        guard packetStatus == noErr, translation.mByte >= 0,
              !translation.mFlags.contains(.bytePacketTranslationFlag_IsEstimate) else {
            throw AudioCueLocatorError.invalidPacketInfo
        }

        let firstSample = targetSample - UInt64(frameTranslation.mFrameOffsetInPacket)
        let packetFrames: UInt32
        if targetPacket + 1 < packetCount {
            var nextFrame = AudioFramePacketTranslation(
                mFrame: 0, mPacket: targetPacket + 1, mFrameOffsetInPacket: 0
            )
            var nextFrameSize = UInt32(MemoryLayout<AudioFramePacketTranslation>.size)
            let nextStatus = AudioFileGetProperty(
                audioFileID, kAudioFilePropertyPacketToFrame, &nextFrameSize, &nextFrame
            )
            guard nextStatus == noErr, nextFrame.mFrame > Int64(firstSample),
                  nextFrame.mFrame - Int64(firstSample) <= Int64(UInt32.max) else {
                throw AudioCueLocatorError.invalidPacketInfo
            }
            packetFrames = UInt32(nextFrame.mFrame - Int64(firstSample))
        } else {
            packetFrames = max(format.mFramesPerPacket, 1)
        }
        return AudioCueLocation(
            decodingStartFramePosition: firstSample,
            fileOffsetInBlock: UInt64(translation.mByte),
            numberOfSamplesInBlock: packetFrames,
            targetSamplePosition: targetSample,
            frameEndSamplePosition: firstSample + UInt64(packetFrames),
            absoluteFileOffset: UInt64(translation.mByte),
            audioStreamOffset: 0,
            usesVariableBlockStrategy: false
        )
    }
}

/// MP3 定位器。逐个验证 MPEG 音频帧头，避免使用系统返回的估算字节位置。
final class MP3AudioCueLocator: AudioCueLocating {
    private var cachedURL: URL?
    private var cachedFrames: [LocatedFrame] = []

    func locateCue(atMilliseconds timeMs: UInt64, in audioFile: URL) throws -> AudioCueLocation {
        if cachedURL != audioFile {
            try load(audioFile)
        }
        guard let first = cachedFrames.first else {
            throw AudioCueLocatorError.unsupportedExperimentalFile
        }
        let targetSample = UInt64((Double(timeMs) * Double(first.frame.sampleRate) / 1_000).rounded(.down))
        guard let located = cachedFrames.first(where: {
            targetSample >= $0.firstSample && targetSample < $0.firstSample + UInt64($0.frame.sampleCount)
        }) else {
            throw AudioCueLocatorError.experimentalFrameNotFound(targetSample: targetSample)
        }
        return AudioCueLocation(
            decodingStartFramePosition: located.firstSample,
            fileOffsetInBlock: UInt64(located.offset - first.offset),
            numberOfSamplesInBlock: located.frame.sampleCount,
            targetSamplePosition: targetSample,
            frameEndSamplePosition: located.firstSample + UInt64(located.frame.sampleCount),
            absoluteFileOffset: UInt64(located.offset),
            audioStreamOffset: UInt64(first.offset),
            usesVariableBlockStrategy: false
        )
    }

    private func load(_ audioFile: URL) throws {
        let data = try Data(contentsOf: audioFile, options: .mappedIfSafe)
        var cursor = id3v2End(in: data)
        var firstSample: UInt64 = 0
        var frames: [LocatedFrame] = []

        while cursor + 4 <= data.count {
            guard let frame = parseFrame(in: data, at: cursor) else {
                cursor += 1
                continue
            }
            frames.append(LocatedFrame(offset: cursor, firstSample: firstSample, frame: frame))
            firstSample += UInt64(frame.sampleCount)
            cursor += frame.byteCount
        }
        guard !frames.isEmpty else { throw AudioCueLocatorError.unsupportedExperimentalFile }
        cachedURL = audioFile
        cachedFrames = frames
    }

    private struct Frame {
        let byteCount: Int
        let sampleCount: UInt32
        let sampleRate: UInt32
    }

    private struct LocatedFrame {
        let offset: Int
        let firstSample: UInt64
        let frame: Frame
    }

    private func id3v2End(in data: Data) -> Int {
        guard data.count >= 10, data.prefix(3) == Data("ID3".utf8) else { return 0 }
        let sizeBytes = data[6...9]
        guard sizeBytes.allSatisfy({ $0 & 0x80 == 0 }) else { return 0 }
        let size = sizeBytes.reduce(0) { ($0 << 7) | Int($1) }
        let footer = data[5] & 0x10 != 0 ? 10 : 0
        return min(data.count, 10 + size + footer)
    }

    private func parseFrame(in data: Data, at offset: Int) -> Frame? {
        guard offset + 4 <= data.count else { return nil }
        let header = UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
        guard header & 0xffe0_0000 == 0xffe0_0000 else { return nil }
        let versionBits = Int((header >> 19) & 0x3)
        let layerBits = Int((header >> 17) & 0x3)
        let bitrateIndex = Int((header >> 12) & 0xf)
        let sampleRateIndex = Int((header >> 10) & 0x3)
        let padding = Int((header >> 9) & 0x1)
        guard versionBits != 1, layerBits == 1,
              (1...14).contains(bitrateIndex), sampleRateIndex < 3 else { return nil }

        let version1 = versionBits == 3
        let bitratesV1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        let bitratesV2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let bitrate = (version1 ? bitratesV1 : bitratesV2)[bitrateIndex] * 1_000
        let baseRates = [44_100, 48_000, 32_000]
        let divisor = versionBits == 3 ? 1 : (versionBits == 2 ? 2 : 4)
        let sampleRate = baseRates[sampleRateIndex] / divisor
        let coefficient = version1 ? 144 : 72
        let byteCount = coefficient * bitrate / sampleRate + padding
        guard byteCount >= 4, offset + byteCount <= data.count else { return nil }
        return Frame(
            byteCount: byteCount,
            sampleCount: version1 ? 1_152 : 576,
            sampleRate: UInt32(sampleRate)
        )
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
        guard let flacOffset = flacMarkerOffset(in: data), flacOffset + 8 <= data.count else {
            throw AudioCueLocatorError.unsupportedFile
        }
        var cursor = flacOffset + 4
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

    /// FLAC files exported by djay may carry an ID3v2 block before the native
    /// FLAC marker. Its size uses four 7-bit (synchsafe) bytes and excludes the
    /// ten-byte ID3 header. A footer, when declared, adds another ten bytes.
    private func flacMarkerOffset(in data: Data) -> Int? {
        let marker = Data("fLaC".utf8)
        if data.count >= 4, data.prefix(4) == marker { return 0 }
        guard data.count >= 14, data.prefix(3) == Data("ID3".utf8) else { return nil }
        let sizeBytes = data[6...9]
        guard sizeBytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
        let payloadSize = sizeBytes.reduce(0) { ($0 << 7) | Int($1) }
        let hasFooter = data[5] & 0x10 != 0
        let offset = 10 + payloadSize + (hasFooter ? 10 : 0)
        guard offset + 4 <= data.count, data[offset..<(offset + 4)] == marker else { return nil }
        return offset
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
