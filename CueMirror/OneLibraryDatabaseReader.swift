import Foundation

struct OneLibraryTrackRecord: Codable, Equatable {
    let contentID: Int64
    let title: String
    let audioPath: String
    let analysisDataFilePath: String
    let savedLoops: [DjaySavedLoop]
}

struct DjaySavedLoop: Codable, Equatable, Identifiable {
    let slot: Int
    let startTimeSeconds: Double
    let endTimeSeconds: Double

    var id: Int { slot }
    var startTimeMs: UInt32 { UInt32((startTimeSeconds * 1_000).rounded()) }
    var endTimeMs: UInt32 { UInt32((endTimeSeconds * 1_000).rounded()) }
}

struct OneLibraryPlaylistRecord: Codable, Equatable {
    let playlistID: Int64
    let sequenceNumber: Int64
    let name: String
    let attribute: Int64
    let parentPlaylistID: Int64
    let contentIDs: [Int64]
}

struct OneLibraryCatalog: Codable, Equatable {
    let tracks: [OneLibraryTrackRecord]
    let playlists: [OneLibraryPlaylistRecord]
    let cueRowCount: Int
}

enum OneLibraryDatabaseError: LocalizedError {
    case pythonUnavailable
    case runtimeUnavailable
    case queryFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .pythonUnavailable:
            return L("未找到 Python 3.14。CueMirror 需要它来只读解析 OneLibrary 数据库。\n\n如尚未安装 Homebrew，请先访问 https://brew.sh。然后在“终端”运行：\nbrew install python@3.14\n\n安装完成后，重新打开 CueMirror。")
        case .runtimeUnavailable: return L("App 内置 SQLCipher 只读运行库缺失。")
        case .queryFailed(let message): return LF("exportLibrary.db 只读查询失败：%@", message)
        case .invalidResponse: return L("exportLibrary.db 返回了无法识别的数据。")
        }
    }
}

/// 只在本机临时副本上打开 SQLCipher 数据库，不直接连接 U 盘数据库。
final class OneLibraryDatabaseReader {
    private let key = "r8gddnr4k847830ar6cqzbkk0el6qytmb3trbbx805jm74vez64i5o8fnrqryqls"

    func read(databaseURL: URL) throws -> OneLibraryCatalog {
        let fileManager = FileManager.default
        let pythonCandidates = [
            "/opt/homebrew/bin/python3.14",
        ].map(URL.init(fileURLWithPath:))
        guard let pythonURL = pythonCandidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw OneLibraryDatabaseError.pythonUnavailable
        }
        guard let runtime = sqlCipherRuntimeURL(),
              fileManager.fileExists(atPath: runtime.path) else {
            throw OneLibraryDatabaseError.runtimeUnavailable
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CueMirror-Database-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        let copiedDatabase = temporaryDirectory.appendingPathComponent("exportLibrary.db")
        try fileManager.copyItem(at: databaseURL, to: copiedDatabase)
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(
                    at: source,
                    to: URL(fileURLWithPath: copiedDatabase.path + suffix)
                )
            }
        }

        let script = #"""
import json, sys
try:
    from sqlcipher3 import dbapi2 as sqlite3
except ModuleNotFoundError:
    import _sqlite3 as sqlite3
db = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
db.row_factory = sqlite3.Row
db.execute("PRAGMA cipher_compatibility=4")
db.execute("PRAGMA key='" + sys.argv[2] + "'")
saved_loops = {}
for row in db.execute("""
SELECT d.content_id,
       CAST(json_extract(j.value, '$.number') AS INTEGER) AS slot,
       CAST(json_extract(j.value, '$.startTime') AS REAL) AS start_time,
       CAST(json_extract(j.value, '$.endTime') AS REAL) AS end_time
FROM djay_content AS d, json_each(d.data, '$.userdata.loopRegions') AS j
WHERE json_extract(j.value, '$.number') BETWEEN 1 AND 8
  AND json_extract(j.value, '$.startTime') >= 0
  AND json_extract(j.value, '$.endTime') > json_extract(j.value, '$.startTime')
ORDER BY d.content_id, slot
"""):
    saved_loops.setdefault(row["content_id"], []).append({
      "slot": row["slot"],
      "startTimeSeconds": row["start_time"],
      "endTimeSeconds": row["end_time"]
    })
tracks = [{
  "contentID": row["content_id"],
  "title": row["title"] or "",
  "audioPath": row["path"] or "",
  "analysisDataFilePath": row["analysisDataFilePath"] or "",
  "savedLoops": saved_loops.get(row["content_id"], [])
} for row in db.execute("SELECT content_id,title,path,analysisDataFilePath FROM content ORDER BY content_id")]
members = {}
for row in db.execute("SELECT playlist_id,content_id,sequenceNo FROM playlist_content ORDER BY playlist_id,sequenceNo"):
    members.setdefault(row["playlist_id"], []).append(row["content_id"])
playlists = [{
  "playlistID": row["playlist_id"],
  "sequenceNumber": row["sequenceNo"] or 0,
  "name": row["name"] or "",
  "attribute": row["attribute"] or 0,
  "parentPlaylistID": row["playlist_id_parent"] or 0,
  "contentIDs": members.get(row["playlist_id"], [])
} for row in db.execute("SELECT playlist_id,sequenceNo,name,attribute,playlist_id_parent FROM playlist ORDER BY sequenceNo,playlist_id")]
print(json.dumps({"tracks": tracks, "playlists": playlists, "cueRowCount": db.execute("SELECT count(*) FROM cue").fetchone()[0]}, ensure_ascii=False))
"""#
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", script, copiedDatabase.path, key]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = runtime.path
        process.environment = environment
        let outputURL = temporaryDirectory.appendingPathComponent("catalog.json")
        let errorURL = temporaryDirectory.appendingPathComponent("query-error.txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        process.waitUntilExit()
        try outputHandle.close()
        try errorHandle.close()
        let outputData = try Data(contentsOf: outputURL)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
            throw OneLibraryDatabaseError.queryFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let result = try? JSONDecoder().decode(OneLibraryCatalog.self, from: outputData) else {
            throw OneLibraryDatabaseError.invalidResponse
        }
        return result
    }

    private func sqlCipherRuntimeURL() -> URL? {
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("SQLCipherPython", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
            if FileManager.default.fileExists(
                atPath: resourceURL.appendingPathComponent("_sqlite3.cpython-314-darwin.so").path
            ) {
                return resourceURL
            }
        }
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("SQLCipherPython", isDirectory: true)
        return development
    }
}
