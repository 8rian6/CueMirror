import Foundation
import XCTest
@testable import CueMirror

final class FLACAudioCueLocatorTests: XCTestCase {
    private let fixture = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["CUEMIRROR_TEST_FLAC"] ?? "/nonexistent/CueMirror-test.flac"
    )
    private let datFixture = fixtureURL("ANLZ0000.DAT")
    private let extFixture = fixtureURL("ANLZ0000.EXT")

    func testCueAMatchesMemoryPCP2LocatorTuple() throws {
        try requireFixture()
        let result = try FLACAudioCueLocator().locateCue(atMilliseconds: 245, in: fixture)
        XCTAssertEqual(result.targetSamplePosition, 10_804)
        XCTAssertEqual(result.decodingStartFramePosition, 10_240)
        XCTAssertEqual(result.frameEndSamplePosition, 11_264)
        XCTAssertEqual(result.absoluteFileOffset, 3_455_269)
        XCTAssertEqual(result.audioStreamOffset, 3_430_428)
        XCTAssertEqual(result.fileOffsetInBlock, 24_841)
        XCTAssertEqual(result.numberOfSamplesInBlock, 1_024)
        XCTAssertFalse(result.usesVariableBlockStrategy)
    }

    func testCueCMatchesMemoryPCP2LocatorTuple() throws {
        try requireFixture()
        let result = try FLACAudioCueLocator().locateCue(atMilliseconds: 76_435, in: fixture)
        XCTAssertEqual(result.targetSamplePosition, 3_370_783)
        XCTAssertEqual(result.decodingStartFramePosition, 3_369_984)
        XCTAssertEqual(result.frameEndSamplePosition, 3_371_008)
        XCTAssertEqual(result.absoluteFileOffset, 17_228_210)
        XCTAssertEqual(result.audioStreamOffset, 3_430_428)
        XCTAssertEqual(result.fileOffsetInBlock, 13_797_782)
        XCTAssertEqual(result.numberOfSamplesInBlock, 1_024)
        XCTAssertFalse(result.usesVariableBlockStrategy)
    }

    func testLocatorDoesNotModifyFLAC() throws {
        try requireFixture()
        let before = try Data(contentsOf: fixture, options: .mappedIfSafe)

        _ = try FLACAudioCueLocator().locateCue(atMilliseconds: 245, in: fixture)
        _ = try FLACAudioCueLocator().locateCue(atMilliseconds: 76_435, in: fixture)

        let after = try Data(contentsOf: fixture, options: .mappedIfSafe)
        XCTAssertEqual(before, after)
    }

    func testExperimentalWriterAddsGreenMemoryCueAtOneMinuteToCopies() throws {
        try requireFixture()
        guard FileManager.default.fileExists(atPath: datFixture.path),
              FileManager.default.fileExists(atPath: extFixture.path) else {
            throw XCTSkip("当前 U 盘配对 ANLZ 样本不存在。")
        }
        let datBefore = try Data(contentsOf: datFixture, options: .mappedIfSafe)
        let extBefore = try Data(contentsOf: extFixture, options: .mappedIfSafe)
        let result = try ExperimentalFLACMemoryCueWriter().makeOutput(
            datData: datBefore,
            extData: extBefore,
            audioFile: fixture,
            cueTimeMs: 60_000
        )

        XCTAssertEqual(result.location.targetSamplePosition, 2_646_000)
        XCTAssertEqual(result.location.decodingStartFramePosition, 2_644_992)
        XCTAssertEqual(result.location.fileOffsetInBlock, 10_637_543)
        XCTAssertEqual(result.location.numberOfSamplesInBlock, 1_024)
        XCTAssertEqual(result.datData.count, datBefore.count + 56)
        XCTAssertEqual(result.extData.count, extBefore.count + 88)
        XCTAssertEqual(try Data(contentsOf: datFixture, options: .mappedIfSafe), datBefore)
        XCTAssertEqual(try Data(contentsOf: extFixture, options: .mappedIfSafe), extBefore)
    }

    private func requireFixture() throws {
        if !FileManager.default.fileExists(atPath: fixture.path) {
            throw XCTSkip("本地 FLAC 研究样本不存在。")
        }
    }
}

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("CueMirror/Research/Backups/Before60sMemoryCue-20260721")
        .appendingPathComponent(name)
}
