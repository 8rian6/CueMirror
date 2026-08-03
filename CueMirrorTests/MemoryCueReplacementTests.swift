import XCTest
@testable import CueMirror

final class MemoryCueReplacementTests: XCTestCase {
    func testHotCueNumberOrderDoesNotControlWriteOrder() {
        let report = makeReport(hot: [cue(9, 9_000), cue(16, 1_000)])
        XCTAssertEqual(report.replacementPlan.replacementCues.map(\.hotCueNumber), [16, 9])
    }

    func testMultipleUnorderedCuesAreSortedByTime() {
        let report = makeReport(hot: [cue(9, 3_000), cue(10, 1_000), cue(11, 2_000)])
        XCTAssertEqual(report.replacementPlan.replacementCues.map(\.timeMs), [1_000, 2_000, 3_000])
    }

    func testExactDuplicatesGenerateOnce() {
        let report = makeReport(hot: [cue(9, 1_000), cue(10, 1_000)])
        XCTAssertTrue(report.replacementPlan.shouldProcess)
        XCTAssertEqual(report.replacementPlan.replacementCues.count, 1)
    }

    func testCueAndLoopAtSameStartConflict() {
        let report = makeReport(hot: [cue(9, 1_000), cue(10, 1_000, type: 2, loop: 2_000)])
        XCTAssertFalse(report.replacementPlan.shouldProcess)
        XCTAssertNotNil(report.replacementPlan.skipReason)
    }

    func testLoopsWithDifferentEndsConflict() {
        let report = makeReport(hot: [
            cue(9, 1_000, type: 2, loop: 2_000),
            cue(10, 1_000, type: 2, loop: 3_000)
        ])
        XCTAssertFalse(report.replacementPlan.shouldProcess)
    }

    func testExistingMemoryCuesAreFullyReplaced() {
        let report = makeReport(memory: [cue(0, 500), cue(0, 750)], hot: [cue(9, 1_000)])
        XCTAssertEqual(report.replacementPlan.deletedMemoryCueCount, 2)
        XCTAssertEqual(report.replacementPlan.generatedMemoryCueCount, 1)
        XCTAssertEqual(report.replacementPlan.replacementCues.first?.timeMs, 1_000)
    }

    func testNoHotCuePreservesExistingMemoryCues() {
        let report = makeReport(memory: [cue(0, 500)], hot: [])
        XCTAssertFalse(report.replacementPlan.shouldProcess)
        XCTAssertEqual(report.replacementPlan.deletedMemoryCueCount, 0)
        XCTAssertEqual(report.memoryCues.count, 1)
    }

    func testDatabaseFailureMakesWholeTrackFail() {
        let result = TrackConversionVerification(
            anlzWriteSucceeded: true,
            databaseWriteSucceeded: false,
            anlzReadbackMatches: true,
            databaseReadbackMatches: false
        )
        XCTAssertFalse(result.isSuccessful)
    }

    func testReadbackComparisonNormalizesByTime() {
        let expected = [cue(9, 2_000), cue(10, 1_000)]
        let actual = [cue(0, 1_000), cue(0, 2_000)]
        XCTAssertTrue(MemoryCueNormalizer.contentsMatch(expected: expected, actual: actual))
    }

    func testSameStructureWithDifferentContentConflicts() {
        let first = cue(9, 1_000, comment: "A")
        let second = cue(10, 1_000, comment: "B")
        XCTAssertFalse(makeReport(hot: [first, second]).replacementPlan.shouldProcess)
    }

    private func makeReport(
        memory: [Pco2CueReport] = [],
        hot: [Pco2CueReport]
    ) -> AnlzFileReport {
        var sections: [Pco2SectionReport] = []
        if !memory.isEmpty { sections.append(section(type: 0, cues: memory, offset: 10)) }
        if !hot.isEmpty { sections.append(section(type: 1, cues: hot, offset: 100)) }
        return AnlzFileReport(
            relativePath: "fixture/ANLZ0000.EXT",
            fileExtension: "EXT",
            fileSize: 1_024,
            hasPMAIHeader: true,
            pco2Sections: sections
        )
    }

    private func section(type: UInt32, cues: [Pco2CueReport], offset: Int) -> Pco2SectionReport {
        Pco2SectionReport(
            offset: offset,
            headerLength: 20,
            totalLength: 20 + cues.count * 64,
            listTypeRaw: type,
            declaredCueCount: cues.count,
            cues: cues,
            parseError: nil
        )
    }

    private func cue(
        _ number: UInt32,
        _ time: UInt32,
        type: UInt8 = 1,
        loop: UInt32 = 0,
        comment: String = ""
    ) -> Pco2CueReport {
        Pco2CueReport(
            entryOffset: Int(number) * 100,
            entryLength: 64,
            hotCueNumber: number,
            cueTypeRaw: type,
            timeMs: time,
            loopTimeMs: loop,
            comment: comment,
            hotCueColorIndex: 0,
            colorRed: 255,
            colorGreen: 0,
            colorBlue: 69
        )
    }
}
