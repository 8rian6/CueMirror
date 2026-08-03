import Foundation
import XCTest
@testable import CueMirror

final class AnlzFormatRoundTripTests: XCTestCase {
    func testManualHotCueAPairHasExactTimeAndMeasuredFieldDifferences() throws {
        try assertManualPointPair(
            hot: hotCueA,
            memory: memoryCueA,
            hotNumber: 1,
            time: 245,
            generatedWord: 10_240,
            generatedTrailing: "0000610900000000000000000000040000000000"
        )
    }

    func testManualHotCueCPairHasExactTimeAndMeasuredFieldDifferences() throws {
        try assertManualPointPair(
            hot: hotCueC,
            memory: memoryCueC,
            hotNumber: 3,
            time: 76_435,
            generatedWord: 3_369_984,
            generatedTrailing: "00d2899600000000000000000000040000000000"
        )
    }

    func testParsingAndCloningPairFixturesDoesNotChangeSourceBytes() throws {
        let originals = [hotCueA, memoryCueA, hotCueC, memoryCueC]
        for raw in originals {
            let snapshot = raw
            let (parsed, _) = try AnlzExtendedCue.parse(raw, at: 0, limit: raw.count)
            let clone = parsed
            XCTAssertEqual(clone.encoded(), raw)
            XCTAssertEqual(raw, snapshot)
            let (reparsed, _) = try AnlzExtendedCue.parse(clone.encoded(), at: 0, limit: raw.count)
            XCTAssertEqual(reparsed, parsed)
        }
    }

    func testExtendedCueEmptyCommentMatchesUpstreamFixtureByteForByte() throws {
        let raw = Data([
            0x50, 0x43, 0x50, 0x32, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x58,
            0x00, 0x00, 0x00, 0x04, 0x01, 0x00, 0x03, 0xe8, 0x00, 0x04, 0x62, 0xf7,
            0xff, 0xff, 0xff, 0xff, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4d, 0x00, 0xff,
            0x00, 0x00, 0x00, 0x00, 0x00, 0xc1, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x30, 0x77, 0x61,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])

        let (cue, end) = try AnlzExtendedCue.parse(raw, at: 0, limit: raw.count)
        XCTAssertEqual(end, raw.count)
        XCTAssertEqual(cue.hotCueNumber, 4)
        XCTAssertEqual(cue.comment?.value, "")
        XCTAssertEqual(cue.comment?.byteLength, 0)
        XCTAssertEqual(cue.colorRed, 0x4d)
        XCTAssertEqual(cue.encoded(), raw)

        let (reparsed, _) = try AnlzExtendedCue.parse(cue.encoded(), at: 0, limit: raw.count)
        XCTAssertEqual(reparsed, cue)
    }

    func testExtendedCueListParseWriteParseIsLossless() throws {
        let entry = upstreamEmptyCommentCue
        var raw = hex("50434f32000000140000006c0000000000010000")
        raw.append(entry)

        let first = try AnlzExtendedCueList.parse(raw)
        XCTAssertEqual(first.listType, 0)
        XCTAssertEqual(first.cues.count, 1)
        XCTAssertEqual(first.encoded(), raw)
        XCTAssertEqual(try AnlzExtendedCueList.parse(first.encoded()), first)
    }

    func testMemoryCueListPCOBRoundTripsByteForByte() throws {
        let raw = hex(
            "50434f420000001800000088000000000000000200000001" +
            "504350540000001c00000038000000000000000000010000ffff0001010003e80004aee2ffffffff00000000000000000000000000000000" +
            "504350540000001c000000380000000000000000000100000000ffff010003e800043d6affffffff00000000000000000000000000000000"
        )
        let list = try AnlzCueList.parse(raw)
        XCTAssertEqual(list.listType, 0)
        XCTAssertEqual(list.cues.count, 2)
        XCTAssertEqual(list.encoded(), raw)
        XCTAssertEqual(try AnlzCueList.parse(list.encoded()), list)
    }

    func testDocumentPreservesUnknownSectionsAndTrailingBytes() throws {
        var raw = hex("504d41490000001c0000002c")
        raw.append(hex("0102030405060708090a0b0c0d0e0f10"))
        raw.append(hex("5a5a5a5a0000000c00000010deadbeef"))
        raw.append(hex("aabb"))

        let document = try AnlzDocument.parse(raw)
        XCTAssertEqual(document.sections.count, 1)
        XCTAssertEqual(document.trailing, hex("aabb"))
        XCTAssertEqual(document.encoded(), raw)
    }

    private var upstreamEmptyCommentCue: Data {
        hex("50435032000000100000005800000004010003e8000462f7ffffffff00010000000000000000000000000000004d00ff0000000000c170000000000000000000000000000230776100000000000000000000100000000000")
    }

    private var hotCueA: Data {
        hex("50435032000000100000003800000001010003e8000000f5ffffffff000000000000000000000000000000000000e0ff0000000000000000")
    }

    private var memoryCueA: Data {
        hex("50435032000000100000005800000000010003e8000000f5ffffffff000100000000000000000000000000000000000000000000000028000000000000000000000000000000610900000000000000000000040000000000")
    }

    private var hotCueC: Data {
        hex("50435032000000100000003800000003010003e800012a93ffffffff000000000000000000000000000000000000e0ff0000000000000000")
    }

    private var memoryCueC: Data {
        hex("50435032000000100000005800000000010003e800012a93ffffffff00010000000000000000000000000000000000000000000000336c0000000000000000000000000000d2899600000000000000000000040000000000")
    }

    private func assertManualPointPair(
        hot hotRaw: Data,
        memory memoryRaw: Data,
        hotNumber: UInt32,
        time: UInt32,
        generatedWord: UInt32,
        generatedTrailing: String
    ) throws {
        let (hot, _) = try AnlzExtendedCue.parse(hotRaw, at: 0, limit: hotRaw.count)
        let (memory, _) = try AnlzExtendedCue.parse(memoryRaw, at: 0, limit: memoryRaw.count)

        XCTAssertEqual(hot.hotCueNumber, hotNumber)
        XCTAssertEqual(memory.hotCueNumber, 0)
        XCTAssertEqual(hot.timeMs, time)
        XCTAssertEqual(memory.timeMs, time)
        XCTAssertEqual(hot.cueType, memory.cueType)
        XCTAssertEqual(hot.loopTimeMs, memory.loopTimeMs)
        XCTAssertEqual(hot.colorID, memory.colorID)
        XCTAssertEqual(hot.loopNumerator, memory.loopNumerator)
        XCTAssertEqual(hot.loopDenominator, memory.loopDenominator)
        XCTAssertEqual(hot.comment, memory.comment)
        XCTAssertEqual(hot.unknownBeforeLoop, hex("00000000000000"))
        XCTAssertEqual(memory.unknownBeforeLoop, hex("01000000000000"))
        XCTAssertEqual(hot.unknownWordsAfterColor, [0, 0])
        XCTAssertEqual(memory.unknownWordsAfterColor, [0, generatedWord, 0, 0, 0])
        XCTAssertEqual(memory.trailing, hex(generatedTrailing))
        XCTAssertEqual(hot.encoded(), hotRaw)
        XCTAssertEqual(memory.encoded(), memoryRaw)
    }

    private func hex(_ text: String) -> Data {
        let compact = text.filter { !$0.isWhitespace }
        precondition(compact.count.isMultiple(of: 2))
        var output = Data()
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            output.append(UInt8(compact[index..<next], radix: 16)!)
            index = next
        }
        return output
    }
}
