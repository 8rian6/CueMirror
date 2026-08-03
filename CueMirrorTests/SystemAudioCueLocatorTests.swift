import Foundation
import XCTest
@testable import CueMirror

final class SystemAudioCueLocatorTests: XCTestCase {
    func testLocatesPCMWaveSampleWithoutChangingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let original = makePCM16Wave(sampleRate: 44_100, channels: 2, seconds: 1)
        try original.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try SystemAudioCueLocator().locateCue(atMilliseconds: 500, in: url)

        XCTAssertEqual(result.targetSamplePosition, 22_050)
        XCTAssertEqual(result.decodingStartFramePosition, 22_050)
        XCTAssertEqual(result.numberOfSamplesInBlock, 1)
        XCTAssertEqual(result.fileOffsetInBlock, 22_050 * 4)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testOptionalRealAIFF() throws {
        try verifyOptionalFixture(
            environmentKey: "CUEMIRROR_TEST_AIFF",
            fallbackPath: "/private/tmp/CueMirrorExperimentalTest.aiff"
        )
    }

    func testOptionalRealMP3() throws {
        try verifyOptionalFixture(
            environmentKey: "CUEMIRROR_TEST_MP3",
            fallbackPath: "/private/tmp/CueMirrorExperimentalTest.mp3",
            locator: MP3AudioCueLocator()
        )
    }

    private func verifyOptionalFixture(
        environmentKey: String,
        fallbackPath: String,
        locator: any AudioCueLocating = SystemAudioCueLocator()
    ) throws {
        let path = ProcessInfo.processInfo.environment[environmentKey] ?? fallbackPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("No \(environmentKey) fixture supplied.")
        }
        let url = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: url)
        let result = try locator.locateCue(atMilliseconds: 500, in: url)
        XCTAssertLessThanOrEqual(result.decodingStartFramePosition, result.targetSamplePosition)
        XCTAssertGreaterThan(result.frameEndSamplePosition, result.targetSamplePosition)
        XCTAssertGreaterThan(result.numberOfSamplesInBlock, 0)
        XCTAssertGreaterThan(result.fileOffsetInBlock, 0)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private func makePCM16Wave(sampleRate: UInt32, channels: UInt16, seconds: UInt32) -> Data {
        let bytesPerSample: UInt16 = 2
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = byteRate * seconds
        var data = Data("RIFF".utf8)
        data.appendLE(36 + dataSize)
        data.append(Data("WAVEfmt ".utf8))
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(channels)
        data.appendLE(sampleRate)
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(UInt16(16))
        data.append(Data("data".utf8))
        data.appendLE(dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
