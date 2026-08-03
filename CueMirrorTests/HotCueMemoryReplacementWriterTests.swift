import Foundation
import XCTest
@testable import CueMirror

final class HotCueMemoryReplacementWriterTests: XCTestCase {
    private let datURL = replacementFixtureURL("ANLZ0000.DAT")
    private let extURL = replacementFixtureURL("ANLZ0000.EXT")
    private let audioURL = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["CUEMIRROR_TEST_FLAC"] ?? "/nonexistent/CueMirror-test.flac"
    )

    func testClearsOldMemoryAndRebuildsFromHC09ThroughHC16() throws {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw XCTSkip("FLAC 研究样本不存在。")
        }
        let datBefore = try Data(contentsOf: datURL)
        let extBefore = try Data(contentsOf: extURL)
        let result = try HotCueMemoryReplacementWriter().makeOutput(
            datData: datBefore,
            extData: extBefore,
            audioFile: audioURL
        )
        XCTAssertEqual(result.deletedMemoryCueCount, 2)
        XCTAssertEqual(result.sourceCueCount, 5)
        XCTAssertEqual(result.generatedMemoryCueCount, 5)

        let dat = try AnlzDocument.parse(result.datData)
        let ext = try AnlzDocument.parse(result.extData)
        let expected: [UInt32] = [137_388, 205_960, 358_343, 373_581, 388_819]
        XCTAssertEqual(memoryTimes(dat), expected)
        XCTAssertEqual(memoryTimes(ext), expected)
        XCTAssertEqual(memoryColors(ext), [0, 0, 0, 0, 0])
        XCTAssertEqual(try Data(contentsOf: datURL), datBefore)
        XCTAssertEqual(try Data(contentsOf: extURL), extBefore)
    }

    func testWriterUsesInjectedExperimentalLocatorWithoutChangingSources() throws {
        let datBefore = try Data(contentsOf: datURL)
        let extBefore = try Data(contentsOf: extURL)
        let result = try HotCueMemoryReplacementWriter().makeOutput(
            datData: datBefore,
            extData: extBefore,
            audioFile: URL(fileURLWithPath: "/nonexistent/experimental.wav"),
            locator: StubAudioCueLocator()
        )

        XCTAssertEqual(result.generatedMemoryCueCount, 5)
        XCTAssertEqual(try Data(contentsOf: datURL), datBefore)
        XCTAssertEqual(try Data(contentsOf: extURL), extBefore)
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

    private func memoryColors(_ document: AnlzDocument) -> [UInt8] {
        document.sections.flatMap { section -> [UInt8] in
            guard case .extendedCueList(let list) = section.content, list.listType == 0 else { return [] }
            return list.cues.compactMap(\.colorID)
        }
    }
}

private struct StubAudioCueLocator: AudioCueLocating {
    func locateCue(atMilliseconds timeMs: UInt64, in audioFile: URL) throws -> AudioCueLocation {
        AudioCueLocation(
            decodingStartFramePosition: timeMs,
            fileOffsetInBlock: timeMs * 2,
            numberOfSamplesInBlock: 1,
            targetSamplePosition: timeMs,
            frameEndSamplePosition: timeMs + 1,
            absoluteFileOffset: timeMs * 2,
            audioStreamOffset: 0,
            usesVariableBlockStrategy: false
        )
    }
}

private func replacementFixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("CueMirror/Research/Backups/Before60sMemoryCue-20260721")
        .appendingPathComponent(name)
}
