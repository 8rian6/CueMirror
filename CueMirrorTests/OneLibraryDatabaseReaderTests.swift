import Foundation
import XCTest
@testable import CueMirror

final class OneLibraryDatabaseReaderTests: XCTestCase {
    private let root = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["CUEMIRROR_TEST_USB"] ?? "/nonexistent/CueMirror-test-USB",
        isDirectory: true
    )

    func testReadsTrackCatalogFromTemporaryDatabaseCopy() throws {
        let database = root.appendingPathComponent("PIONEER/rekordbox/exportLibrary.db")
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw XCTSkip("当前 OneLibrary U 盘不存在。")
        }
        let catalog = try OneLibraryDatabaseReader().read(databaseURL: database)
        XCTAssertEqual(catalog.cueRowCount, 0)
        XCTAssertEqual(catalog.tracks.count, 1)
        XCTAssertEqual(catalog.tracks.first?.title, "Vanderkraft - Onirisme Nocturne")
        XCTAssertEqual(
            catalog.tracks.first?.analysisDataFilePath,
            "/PIONEER/USBANLZ/P04A/000189B4/ANLZ0000.DAT"
        )
    }

    func testScannerMapsDatabaseTrackToAllHotCues() throws {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("当前 OneLibrary U 盘不存在。")
        }
        let summary = try AnlzScanner().scan(rootURL: root)
        XCTAssertNil(summary.databaseReadError)
        XCTAssertEqual(summary.databaseTracks.count, 1)
        XCTAssertEqual(summary.databaseTracks.first?.hotCues.count, 13)
        XCTAssertEqual(summary.databaseTracks.first?.hotCues.map(\.hotCueNumber), Array(1...13).map(UInt32.init))
    }
}
