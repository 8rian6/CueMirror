import Foundation

struct HotCueMemoryReplacementResult {
    let datData: Data
    let extData: Data
    let sourceCueCount: Int
    let deletedMemoryCueCount: Int
    let generatedMemoryCueCount: Int
}

enum HotCueMemoryReplacementError: LocalizedError {
    case missingList(String)
    case noSources
    case unsupportedCue(String)
    case duplicateOrConflict(String)
    case locatorOverflow
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingList(let value): return LF("缺少 %@ Cue 列表。", value)
        case .noSources: return L("没有找到 HC09–HC16 或 djay Saved Loop。")
        case .unsupportedCue(let value): return LF("暂不支持：%@", value)
        case .duplicateOrConflict(let value): return value
        case .locatorOverflow: return L("音频定位值超出 ANLZ 字段范围。")
        case .verificationFailed(let value): return LF("转换回读验证失败：%@", value)
        }
    }
}

/// 清除旧 Memory Cue，并使用调用方提供的格式定位器从 HC09–HC16 重建 Memory Cue 集合。
struct HotCueMemoryReplacementWriter {
    func makeOutput(
        datData: Data,
        extData: Data,
        audioFile: URL,
        savedLoops: [DjaySavedLoop] = [],
        activeSavedLoopSlot: Int? = nil,
        locator: any AudioCueLocating = FLACAudioCueLocator()
    ) throws -> HotCueMemoryReplacementResult {
        var dat = try AnlzDocument.parse(datData)
        var ext = try AnlzDocument.parse(extData)
        let datHotBefore = hotSections(dat)
        let extHotBefore = hotSections(ext)

        guard let extendedHot = ext.sections.compactMap({ section -> AnlzExtendedCueList? in
            guard case .extendedCueList(let list) = section.content, list.listType == 1 else { return nil }
            return list
        }).first else { throw HotCueMemoryReplacementError.missingList("EXT Hot PCO2") }
        let hotSources = extendedHot.cues
            .filter { (9...16).contains($0.hotCueNumber) }
            .map(Source.hotCue)
        let loopSources = savedLoops.map(Source.savedLoop)
        let sources = hotSources + loopSources
        guard !sources.isEmpty else { throw HotCueMemoryReplacementError.noSources }
        guard sources.count <= 10 else {
            throw HotCueMemoryReplacementError.unsupportedCue(L("HC09–HC16 与 Saved Loop 合计超过 10 条 Memory 容量"))
        }
        guard hotSources.allSatisfy({ $0.cueType == 1 || $0.cueType == 2 }) else {
            throw HotCueMemoryReplacementError.unsupportedCue(L("HC09–HC16 中包含未知 Cue 类型"))
        }
        guard sources.allSatisfy({ $0.cueType != 2 || $0.loopTimeMs > $0.timeMs }) else {
            throw HotCueMemoryReplacementError.unsupportedCue(L("存在 Loop Out 不大于 Loop In 的 Saved Loop"))
        }
        let grouped = Dictionary(grouping: sources, by: { $0.timeMs })
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            throw HotCueMemoryReplacementError.duplicateOrConflict(L("HC09–HC16 存在相同开始时间，整首曲目已跳过。"))
        }
        let sortedSources = sources.sorted {
            if $0.timeMs != $1.timeMs { return $0.timeMs < $1.timeMs }
            return $0.sortSlot < $1.sortSlot
        }

        let existingDATMemory = dat.sections.compactMap { section -> AnlzCueList? in
            guard case .cueList(let list) = section.content, list.listType == 0 else { return nil }
            return list
        }.first
        let existingEXTMemory = ext.sections.compactMap { section -> AnlzExtendedCueList? in
            guard case .extendedCueList(let list) = section.content, list.listType == 0 else { return nil }
            return list
        }.first
        let datTemplate = existingDATMemory?.cues.first
        let extTemplate = existingEXTMemory?.cues.first.flatMap(isUsableMemoryTemplate(_:))

        var newPCPT: [AnlzCue] = []
        var newPCP2: [AnlzExtendedCue] = []
        for (index, source) in sortedSources.enumerated() {
            let location = try locator.locateCue(atMilliseconds: UInt64(source.timeMs), in: audioFile)
            guard location.decodingStartFramePosition <= UInt64(UInt32.max),
                  location.fileOffsetInBlock <= UInt64(UInt32.max) else {
                throw HotCueMemoryReplacementError.locatorOverflow
            }

            var pcpt = datTemplate ?? source.hotCue.flatMap { matchingDATSource(for: $0, in: dat) } ?? standardMemoryPCPT()
            pcpt.hotCueNumber = 0
            let isActiveLoop = activeSavedLoopSlot.map { source.savedLoopSlot == $0 } ?? false
            pcpt.status = isActiveLoop ? 4 : 0
            pcpt.unknown1 = 0x0001_0000
            pcpt.orderFirst = index == 0 ? UInt16.max : UInt16(index - 1)
            pcpt.orderLast = index == sortedSources.count - 1 ? UInt16.max : UInt16(index + 1)
            pcpt.cueType = source.cueType
            pcpt.timeMs = source.timeMs
            pcpt.loopTimeMs = source.cueType == 2 ? source.loopTimeMs : UInt32.max
            pcpt.unknownTrailing = Data(repeating: 0, count: 16)
            newPCPT.append(pcpt)

            var pcp2 = extTemplate ?? standardMemoryPCP2()
            pcp2.hotCueNumber = 0
            pcp2.cueType = source.cueType
            pcp2.timeMs = source.timeMs
            pcp2.loopTimeMs = source.cueType == 2 ? source.loopTimeMs : UInt32.max
            pcp2.colorID = 0 // 已确认的默认绿色；自定义颜色映射尚未启用。
            if !pcp2.unknownBeforeLoop.isEmpty { pcp2.unknownBeforeLoop[0] = 1 }
            pcp2.loopNumerator = source.cueType == 2 ? source.loopNumerator : 0
            pcp2.loopDenominator = source.cueType == 2 ? source.loopDenominator : 0
            pcp2.comment = .init(value: source.comment ?? "")
            pcp2.hotCueColorIndex = 0
            pcp2.colorRed = 0
            pcp2.colorGreen = 0
            pcp2.colorBlue = 0
            pcp2.unknownWordsAfterColor[1] = UInt32(location.decodingStartFramePosition)
            pcp2.trailing.setUInt32BE(UInt32(location.fileOffsetInBlock), at: 0)
            pcp2.trailing.setUInt32BE(location.numberOfSamplesInBlock, at: 12)
            pcp2.header.totalLength = UInt32(pcp2.encoded().count)
            newPCP2.append(pcp2)
        }

        let deletedCount = existingEXTMemory?.cues.count ?? 0
        var datMemory = existingDATMemory ?? standardMemoryPCOB()
        datMemory.cues = newPCPT
        datMemory.memoryCount = newPCPT.isEmpty ? UInt32.max : UInt32(newPCPT.count - 1)
        datMemory.header.totalLength = datMemory.header.headerLength + UInt32(newPCPT.reduce(0) { $0 + Int($1.header.totalLength) })
        replaceOrInsertMemoryPCOB(datMemory, in: &dat)

        ensureEmptyMemoryPCOB(in: &ext)
        var extMemory = existingEXTMemory ?? standardMemoryPCO2()
        extMemory.cues = newPCP2
        extMemory.header.totalLength = extMemory.header.headerLength + UInt32(newPCP2.reduce(0) { $0 + Int($1.header.totalLength) })
        replaceOrInsertMemoryPCO2(extMemory, in: &ext)

        let outputDAT = dat.encoded()
        let outputEXT = ext.encoded()
        let datReadback = try AnlzDocument.parse(outputDAT)
        let extReadback = try AnlzDocument.parse(outputEXT)
        guard datReadback.encoded() == outputDAT, extReadback.encoded() == outputEXT else {
            throw HotCueMemoryReplacementError.verificationFailed(L("ANLZ 逐字节往返失败"))
        }
        guard hotSections(datReadback) == datHotBefore, hotSections(extReadback) == extHotBefore else {
            throw HotCueMemoryReplacementError.verificationFailed(L("原 Hot Cue 区块发生变化"))
        }
        let expectedTimes = sortedSources.map(\.timeMs)
        guard memoryTimes(datReadback) == expectedTimes, memoryTimes(extReadback) == expectedTimes else {
            throw HotCueMemoryReplacementError.verificationFailed(L("Memory Cue 时间或排序不一致"))
        }
        let activeStatuses = datReadback.sections.flatMap { section -> [UInt32] in
            guard case .cueList(let list) = section.content, list.listType == 0 else { return [] }
            return list.cues.filter { $0.cueType == 2 }.map(\.status)
        }
        guard activeStatuses.filter({ $0 == 4 }).count <= 1,
              activeStatuses.allSatisfy({ $0 == 0 || $0 == 4 }) else {
            throw HotCueMemoryReplacementError.verificationFailed(L("Active Memory Loop 标志不一致"))
        }
        return HotCueMemoryReplacementResult(
            datData: outputDAT,
            extData: outputEXT,
            sourceCueCount: sources.count,
            deletedMemoryCueCount: deletedCount,
            generatedMemoryCueCount: newPCP2.count
        )
    }

    private func isUsableMemoryTemplate(_ cue: AnlzExtendedCue) -> AnlzExtendedCue? {
        cue.unknownWordsAfterColor.count == 5 && cue.trailing.count == 20 ? cue : nil
    }

    private func standardMemoryPCPT() -> AnlzCue {
        AnlzCue(
            header: .init(magic: "PCPT", headerLength: 28, totalLength: 56),
            hotCueNumber: 0, status: 0, unknown1: 0x0001_0000,
            orderFirst: .max, orderLast: .max, cueType: 1, unknown2: 0,
            unknown3: 1000, timeMs: 0, loopTimeMs: .max,
            unknownTrailing: Data(repeating: 0, count: 16)
        )
    }

    private func standardMemoryPCP2() -> AnlzExtendedCue {
        AnlzExtendedCue(
            header: .init(magic: "PCP2", headerLength: 16, totalLength: 88),
            hotCueNumber: 0, cueType: 1, unknown1: 0, unknown2: 1000,
            timeMs: 0, loopTimeMs: .max, colorID: 0,
            unknownBeforeLoop: Data([1, 0, 0, 0, 0, 0, 0]),
            loopNumerator: 0, loopDenominator: 0,
            comment: .init(value: ""), hotCueColorIndex: 0,
            colorRed: 0, colorGreen: 0, colorBlue: 0,
            unknownWordsAfterColor: [0, 0, 0, 0, 0],
            trailing: Data(repeating: 0, count: 20)
        )
    }

    private func standardMemoryPCOB() -> AnlzCueList {
        AnlzCueList(
            header: .init(magic: "PCOB", headerLength: 24, totalLength: 24),
            listType: 0, unknown: 0, memoryCount: .max,
            headerExtra: Data(), cues: [], trailing: Data()
        )
    }

    private func standardMemoryPCO2() -> AnlzExtendedCueList {
        AnlzExtendedCueList(
            header: .init(magic: "PCO2", headerLength: 20, totalLength: 20),
            listType: 0, unknown: 0, headerExtra: Data(), cues: [], trailing: Data()
        )
    }

    private func matchingDATSource(for source: AnlzExtendedCue, in document: AnlzDocument) -> AnlzCue? {
        document.sections.compactMap { section -> AnlzCueList? in
            guard case .cueList(let list) = section.content, list.listType == 1 else { return nil }
            return list
        }.flatMap(\.cues).first {
            $0.hotCueNumber == source.hotCueNumber && $0.timeMs == source.timeMs
        }
    }

    private func replaceOrInsertMemoryPCOB(_ list: AnlzCueList, in document: inout AnlzDocument) {
        if let index = document.sections.firstIndex(where: {
            if case .cueList(let value) = $0.content { return value.listType == 0 }
            return false
        }) {
            let oldLength = UInt32(document.sections[index].encoded().count)
            document.sections[index].content = .cueList(list)
            document.header.totalLength = document.header.totalLength - oldLength + list.header.totalLength
        } else {
            let insertion = (document.sections.lastIndex(where: {
                if case .cueList = $0.content { return true }
                return false
            }) ?? (document.sections.count - 1)) + 1
            document.sections.insert(.init(content: .cueList(list)), at: insertion)
            document.header.totalLength += list.header.totalLength
        }
    }

    private func replaceOrInsertMemoryPCO2(_ list: AnlzExtendedCueList, in document: inout AnlzDocument) {
        if let index = document.sections.firstIndex(where: {
            if case .extendedCueList(let value) = $0.content { return value.listType == 0 }
            return false
        }) {
            let oldLength = UInt32(document.sections[index].encoded().count)
            document.sections[index].content = .extendedCueList(list)
            document.header.totalLength = document.header.totalLength - oldLength + list.header.totalLength
        } else {
            let insertion = (document.sections.lastIndex(where: {
                if case .extendedCueList = $0.content { return true }
                return false
            }) ?? (document.sections.count - 1)) + 1
            document.sections.insert(.init(content: .extendedCueList(list)), at: insertion)
            document.header.totalLength += list.header.totalLength
        }
    }

    private func ensureEmptyMemoryPCOB(in document: inout AnlzDocument) {
        let exists = document.sections.contains {
            if case .cueList(let list) = $0.content { return list.listType == 0 }
            return false
        }
        guard !exists else { return }
        replaceOrInsertMemoryPCOB(standardMemoryPCOB(), in: &document)
    }

    private func hotSections(_ document: AnlzDocument) -> [Data] {
        document.sections.compactMap {
            switch $0.content {
            case .cueList(let list) where list.listType == 1: return list.encoded()
            case .extendedCueList(let list) where list.listType == 1: return list.encoded()
            default: return nil
            }
        }
    }

    private func memoryTimes(_ document: AnlzDocument) -> [UInt32] {
        document.sections.flatMap {
            switch $0.content {
            case .cueList(let list) where list.listType == 0: return list.cues.map(\.timeMs)
            case .extendedCueList(let list) where list.listType == 0: return list.cues.map(\.timeMs)
            default: return []
            }
        }
    }
}

private struct Source {
    let hotCue: AnlzExtendedCue?
    let savedLoopSlot: Int?
    let cueType: UInt8
    let timeMs: UInt32
    let loopTimeMs: UInt32
    let loopNumerator: UInt16?
    let loopDenominator: UInt16?
    let comment: String?
    let sortSlot: Int

    static func hotCue(_ cue: AnlzExtendedCue) -> Self {
        Self(
            hotCue: cue, savedLoopSlot: nil, cueType: cue.cueType,
            timeMs: cue.timeMs, loopTimeMs: cue.loopTimeMs,
            loopNumerator: cue.loopNumerator, loopDenominator: cue.loopDenominator,
            comment: cue.comment?.value, sortSlot: 100 + Int(cue.hotCueNumber)
        )
    }

    static func savedLoop(_ loop: DjaySavedLoop) -> Self {
        Self(
            hotCue: nil, savedLoopSlot: loop.slot, cueType: 2,
            timeMs: loop.startTimeMs, loopTimeMs: loop.endTimeMs,
            loopNumerator: 0, loopDenominator: 0,
            comment: nil, sortSlot: loop.slot
        )
    }
}

private extension Data {
    mutating func setUInt32BE(_ value: UInt32, at offset: Int) {
        replaceSubrange(offset..<offset + 4, with: [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ])
    }
}
