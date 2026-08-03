import Foundation

struct MemoryCueCandidate: Identifiable {
    let sourceSectionOffset: Int
    let sourceCue: Pco2CueReport
    let isExactDuplicate: Bool
    let conflictReason: String?

    var id: String { "\(sourceSectionOffset)-\(sourceCue.id)" }
    var displayName: String { LF("%@ → Memory Cue 候选", sourceCue.slotLabel) }
    var isConvertible: Bool { !isExactDuplicate && conflictReason == nil }

    var statusDescription: String {
        if let conflictReason { return conflictReason }
        if isExactDuplicate { return L("与另一条来源完全重复，只生成一次") }
        return L("将写入新 Memory Cue 集合")
    }
}

struct MemoryCueReplacementPlan {
    let existingMemoryCues: [Pco2CueReport]
    let candidates: [MemoryCueCandidate]
    let replacementCues: [Pco2CueReport]
    let skipReason: String?

    var shouldProcess: Bool { !replacementCues.isEmpty && skipReason == nil }
    var deletedMemoryCueCount: Int { shouldProcess ? existingMemoryCues.count : 0 }
    var generatedMemoryCueCount: Int { shouldProcess ? replacementCues.count : 0 }
}

extension Pco2CueReport {
    func hasSameStructure(as other: Pco2CueReport) -> Bool {
        cueTypeRaw == other.cueTypeRaw &&
        timeMs == other.timeMs &&
        (!isLoop || loopTimeMs == other.loopTimeMs)
    }

    func hasSameContent(as other: Pco2CueReport) -> Bool {
        hasSameStructure(as: other) &&
        comment == other.comment &&
        hotCueColorIndex == other.hotCueColorIndex &&
        colorRed == other.colorRed &&
        colorGreen == other.colorGreen &&
        colorBlue == other.colorBlue
    }
}

enum MemoryCueReplacementPlanner {
    static func makePlan(for report: AnlzFileReport) -> MemoryCueReplacementPlan {
        let existing = report.memoryCues
        let sources = report.hotCues9Through16
        guard !sources.isEmpty else {
            return MemoryCueReplacementPlan(
                existingMemoryCues: existing,
                candidates: [],
                replacementCues: [],
                skipReason: L("没有 HC09–HC16，保留原有 Memory Cue")
            )
        }

        var accepted: [Pco2CueReport] = []
        var candidates: [MemoryCueCandidate] = []
        var planConflict: String?

        for source in sources {
            let cue = source.cue
            let sameStart = accepted.filter { $0.timeMs == cue.timeMs }
            let exact = sameStart.first { $0.hasSameContent(as: cue) }
            let sameStructure = sameStart.first { $0.hasSameStructure(as: cue) }
            let conflict: String?

            if exact != nil {
                conflict = nil
            } else if sameStructure != nil {
                conflict = L("相同结构的 Cue 评论或颜色不同")
            } else if let other = sameStart.first {
                conflict = other.cueTypeRaw != cue.cueTypeRaw
                    ? L("相同开始时间同时存在 Cue 和 Loop")
                    : L("相同开始时间的 Loop 结束时间不同")
            } else {
                conflict = nil
            }

            if let conflict { planConflict = planConflict ?? conflict }
            if exact == nil && conflict == nil { accepted.append(cue) }
            candidates.append(
                MemoryCueCandidate(
                    sourceSectionOffset: source.sectionOffset,
                    sourceCue: cue,
                    isExactDuplicate: exact != nil,
                    conflictReason: conflict
                )
            )
        }

        let sorted = accepted.sorted(by: memoryCueWriteOrder)
        let limitConflict = sorted.count > 10 ? L("HC09–HC16 去重后超过 10 条") : nil
        return MemoryCueReplacementPlan(
            existingMemoryCues: existing,
            candidates: candidates,
            replacementCues: planConflict == nil && limitConflict == nil ? sorted : [],
            skipReason: planConflict ?? limitConflict
        )
    }

    static func memoryCueWriteOrder(_ lhs: Pco2CueReport, _ rhs: Pco2CueReport) -> Bool {
        if lhs.timeMs != rhs.timeMs { return lhs.timeMs < rhs.timeMs }
        if lhs.loopTimeMs != rhs.loopTimeMs { return lhs.loopTimeMs < rhs.loopTimeMs }
        return lhs.hotCueNumber < rhs.hotCueNumber
    }
}

extension AnlzFileReport {
    var allHotCues: [Pco2CueReport] {
        pco2Sections
            .filter { $0.listTypeRaw == 1 }
            .flatMap(\.cues)
            .filter { $0.hotCueNumber > 0 }
            .sorted { $0.hotCueNumber < $1.hotCueNumber }
    }

    var memoryCues: [Pco2CueReport] {
        pco2Sections.filter { $0.listTypeRaw == 0 }.flatMap(\.cues)
    }

    var hotCues9Through16: [(sectionOffset: Int, cue: Pco2CueReport)] {
        pco2Sections
            .filter { $0.listTypeRaw == 1 }
            .flatMap { section in
                section.cues.compactMap { cue in
                    guard (9...16).contains(cue.hotCueNumber) else { return nil }
                    return (section.offset, cue)
                }
            }
            .sorted { $0.cue.hotCueNumber < $1.cue.hotCueNumber }
    }

    var replacementPlan: MemoryCueReplacementPlan {
        MemoryCueReplacementPlanner.makePlan(for: self)
    }
    var memoryCueCandidates: [MemoryCueCandidate] { replacementPlan.candidates }
    var parseErrorCount: Int { pco2Sections.filter { $0.parseError != nil }.count }
    var projectedMemoryCueCount: Int { replacementPlan.generatedMemoryCueCount }
    var hasCapacityConflict: Bool { replacementPlan.skipReason != nil && !hotCues9Through16.isEmpty }
}

extension ScanSummary {
    var filesContainingHotCues9Through16: Int { files.filter { !$0.hotCues9Through16.isEmpty }.count }
    var candidateCount: Int { files.reduce(0) { $0 + $1.memoryCueCandidates.count } }
    var convertibleCandidateCount: Int {
        files.reduce(0) { $0 + ($1.replacementPlan.shouldProcess ? $1.replacementPlan.generatedMemoryCueCount : 0) }
    }
    var conflictFileCount: Int { files.filter { $0.replacementPlan.skipReason != nil && !$0.hotCues9Through16.isEmpty }.count }
    var parseErrorCount: Int { files.reduce(0) { $0 + $1.parseErrorCount } }
    var candidateFiles: [AnlzFileReport] { files.filter { !$0.memoryCueCandidates.isEmpty } }
    var processableTrackCount: Int { files.filter { $0.replacementPlan.shouldProcess }.count }
    var deletedMemoryCueCount: Int { files.reduce(0) { $0 + $1.replacementPlan.deletedMemoryCueCount } }
    var generatedMemoryCueCount: Int { files.reduce(0) { $0 + $1.replacementPlan.generatedMemoryCueCount } }
}
