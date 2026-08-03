import Foundation

struct ExperimentalMemoryCueWriteResult: Equatable {
    var datData: Data
    var extData: Data
    var location: AudioCueLocation
    var cueTimeMs: UInt32
}

enum ExperimentalMemoryCueWriterError: LocalizedError, Equatable {
    case unsupportedCueTime
    case missingMemoryCueList(file: String)
    case duplicateCue(timeMs: UInt32)
    case unsupportedTemplate
    case invalidLocatorStorage
    case verificationFailed(String)
    case sourceAndOutputAreSame

    var errorDescription: String? {
        switch self {
        case .unsupportedCueTime: return "Cue 时间超出 ANLZ 毫秒字段范围。"
        case .missingMemoryCueList(let file): return "\(file) 缺少可克隆的 Memory Cue 列表。"
        case .duplicateCue(let time): return "\(time) ms 已存在 Memory Cue。"
        case .unsupportedTemplate: return "现有 Memory Cue 模板不是已验证的 88 字节普通 FLAC Cue。"
        case .invalidLocatorStorage: return "Memory PCP2 定位字段长度不符合已验证结构。"
        case .verificationFailed(let reason): return "写后验证失败：\(reason)"
        case .sourceAndOutputAreSame: return "实验写入器禁止覆盖来源目录。"
        }
    }
}

/// 仅用于已验证结构的普通 FLAC Memory Cue，并且只产生输出副本。
struct ExperimentalFLACMemoryCueWriter {
    func makeOutput(
        datData: Data,
        extData: Data,
        audioFile: URL,
        cueTimeMs: UInt64
    ) throws -> ExperimentalMemoryCueWriteResult {
        guard cueTimeMs <= UInt64(UInt32.max) else {
            throw ExperimentalMemoryCueWriterError.unsupportedCueTime
        }
        let time = UInt32(cueTimeMs)
        let location = try FLACAudioCueLocator().locateCue(atMilliseconds: cueTimeMs, in: audioFile)
        var dat = try AnlzDocument.parse(datData)
        var ext = try AnlzDocument.parse(extData)

        let originalDATHot = hotSections(in: dat)
        let originalEXTHot = hotSections(in: ext)
        try appendDATMemoryCue(timeMs: time, document: &dat)
        try appendEXTMemoryCue(timeMs: time, location: location, document: &ext)
        let outputDAT = dat.encoded()
        let outputEXT = ext.encoded()

        try verify(
            dat: outputDAT,
            ext: outputEXT,
            timeMs: time,
            location: location,
            originalDATHot: originalDATHot,
            originalEXTHot: originalEXTHot
        )
        return ExperimentalMemoryCueWriteResult(
            datData: outputDAT,
            extData: outputEXT,
            location: location,
            cueTimeMs: time
        )
    }

    func writeOutputCopies(
        datSource: URL,
        extSource: URL,
        audioFile: URL,
        outputDirectory: URL,
        cueTimeMs: UInt64
    ) throws -> ExperimentalMemoryCueWriteResult {
        let sourceDirectory = datSource.deletingLastPathComponent().standardizedFileURL
        guard outputDirectory.standardizedFileURL != sourceDirectory else {
            throw ExperimentalMemoryCueWriterError.sourceAndOutputAreSame
        }
        let datInput = try Data(contentsOf: datSource, options: .mappedIfSafe)
        let extInput = try Data(contentsOf: extSource, options: .mappedIfSafe)
        let result = try makeOutput(
            datData: datInput,
            extData: extInput,
            audioFile: audioFile,
            cueTimeMs: cueTimeMs
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try result.datData.write(to: outputDirectory.appendingPathComponent(datSource.lastPathComponent), options: .atomic)
        try result.extData.write(to: outputDirectory.appendingPathComponent(extSource.lastPathComponent), options: .atomic)
        return result
    }

    private func appendDATMemoryCue(timeMs: UInt32, document: inout AnlzDocument) throws {
        guard let index = document.sections.firstIndex(where: {
            if case .cueList(let list) = $0.content { return list.listType == 0 && !list.cues.isEmpty }
            return false
        }), case .cueList(var list) = document.sections[index].content else {
            throw ExperimentalMemoryCueWriterError.missingMemoryCueList(file: "DAT")
        }
        guard !list.cues.contains(where: { $0.timeMs == timeMs }) else {
            throw ExperimentalMemoryCueWriterError.duplicateCue(timeMs: timeMs)
        }
        guard let template = list.cues.first(where: {
            $0.hotCueNumber == 0 && $0.cueType == 1 && $0.header.totalLength == 56
        }), let previousLast = list.cues.firstIndex(where: { $0.orderLast == UInt16.max }) else {
            throw ExperimentalMemoryCueWriterError.unsupportedTemplate
        }

        let newIndex = list.cues.count
        guard newIndex <= Int(UInt16.max) else { throw ExperimentalMemoryCueWriterError.unsupportedTemplate }
        list.cues[previousLast].orderLast = UInt16(newIndex)
        var cue = template
        cue.hotCueNumber = 0
        cue.status = 0
        cue.unknown1 = 0x0001_0000
        cue.orderFirst = UInt16(previousLast)
        cue.orderLast = UInt16.max
        cue.cueType = 1
        cue.timeMs = timeMs
        cue.loopTimeMs = UInt32.max
        cue.unknownTrailing = Data(repeating: 0, count: 16)
        list.cues.append(cue)
        list.memoryCount = UInt32(newIndex)
        list.header.totalLength += cue.header.totalLength
        document.sections[index].content = .cueList(list)
        document.header.totalLength += cue.header.totalLength
    }

    private func appendEXTMemoryCue(
        timeMs: UInt32,
        location: AudioCueLocation,
        document: inout AnlzDocument
    ) throws {
        guard let index = document.sections.firstIndex(where: {
            if case .extendedCueList(let list) = $0.content { return list.listType == 0 && !list.cues.isEmpty }
            return false
        }), case .extendedCueList(var list) = document.sections[index].content else {
            throw ExperimentalMemoryCueWriterError.missingMemoryCueList(file: "EXT")
        }
        guard !list.cues.contains(where: { $0.timeMs == timeMs }) else {
            throw ExperimentalMemoryCueWriterError.duplicateCue(timeMs: timeMs)
        }
        guard var cue = list.cues.first(where: {
            $0.hotCueNumber == 0 && $0.cueType == 1 && $0.header.totalLength == 88 &&
                $0.unknownWordsAfterColor.count == 5 && $0.trailing.count == 20
        }) else {
            throw ExperimentalMemoryCueWriterError.unsupportedTemplate
        }
        guard location.decodingStartFramePosition <= UInt64(UInt32.max),
              location.fileOffsetInBlock <= UInt64(UInt32.max) else {
            throw ExperimentalMemoryCueWriterError.invalidLocatorStorage
        }

        cue.hotCueNumber = 0
        cue.cueType = 1
        cue.timeMs = timeMs
        cue.loopTimeMs = UInt32.max
        cue.colorID = 0 // Memory Cue 默认绿色。
        if !cue.unknownBeforeLoop.isEmpty { cue.unknownBeforeLoop[0] = 1 }
        cue.loopNumerator = 0
        cue.loopDenominator = 0
        cue.comment = AnlzLenPrefixedWideString(value: "")
        cue.hotCueColorIndex = 0
        cue.colorRed = 0
        cue.colorGreen = 0
        cue.colorBlue = 0
        cue.unknownWordsAfterColor[1] = UInt32(location.decodingStartFramePosition)
        cue.trailing.replaceUInt32BE(at: 0, with: UInt32(location.fileOffsetInBlock))
        cue.trailing.replaceUInt32BE(at: 12, with: location.numberOfSamplesInBlock)

        list.cues.append(cue)
        list.cues = list.cues.enumerated().sorted {
            if $0.element.timeMs != $1.element.timeMs { return $0.element.timeMs < $1.element.timeMs }
            return $0.offset < $1.offset
        }.map(\.element)
        list.header.totalLength += cue.header.totalLength
        document.sections[index].content = .extendedCueList(list)
        document.header.totalLength += cue.header.totalLength
    }

    private func hotSections(in document: AnlzDocument) -> [Data] {
        document.sections.compactMap {
            switch $0.content {
            case .cueList(let list) where list.listType == 1: return list.encoded()
            case .extendedCueList(let list) where list.listType == 1: return list.encoded()
            default: return nil
            }
        }
    }

    private func verify(
        dat: Data,
        ext: Data,
        timeMs: UInt32,
        location: AudioCueLocation,
        originalDATHot: [Data],
        originalEXTHot: [Data]
    ) throws {
        let parsedDAT = try AnlzDocument.parse(dat)
        let parsedEXT = try AnlzDocument.parse(ext)
        guard parsedDAT.encoded() == dat, parsedEXT.encoded() == ext else {
            throw ExperimentalMemoryCueWriterError.verificationFailed("ANLZ 无损回读不一致")
        }
        guard hotSections(in: parsedDAT) == originalDATHot,
              hotSections(in: parsedEXT) == originalEXTHot else {
            throw ExperimentalMemoryCueWriterError.verificationFailed("原 Hot Cue 区块发生变化")
        }
        let datCue = parsedDAT.sections.compactMap { section -> AnlzCue? in
            guard case .cueList(let list) = section.content, list.listType == 0 else { return nil }
            return list.cues.first(where: { $0.timeMs == timeMs })
        }.first
        let extCue = parsedEXT.sections.compactMap { section -> AnlzExtendedCue? in
            guard case .extendedCueList(let list) = section.content, list.listType == 0 else { return nil }
            return list.cues.first(where: { $0.timeMs == timeMs })
        }.first
        guard datCue?.cueType == 1, extCue?.cueType == 1,
              extCue?.colorID == 0,
              extCue?.unknownWordsAfterColor[safe: 1] == UInt32(location.decodingStartFramePosition),
              extCue?.trailing.uint32BE(at: 0) == UInt32(location.fileOffsetInBlock),
              extCue?.trailing.uint32BE(at: 12) == location.numberOfSamplesInBlock else {
            throw ExperimentalMemoryCueWriterError.verificationFailed("新 Memory Cue 字段不匹配")
        }
    }
}

private extension Data {
    mutating func replaceUInt32BE(at offset: Int, with value: UInt32) {
        replaceSubrange(offset..<offset + 4, with: [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ])
    }

    func uint32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 |
            UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
