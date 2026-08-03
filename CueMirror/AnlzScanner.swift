import Foundation

// MARK: - 单个 PCP2 Cue 条目

struct Pco2CueReport: Identifiable {
    var id: String {
        "\(entryOffset)-\(hotCueNumber)-\(timeMs)"
    }

    let entryOffset: Int
    let entryLength: Int

    let hotCueNumber: UInt32
    let cueTypeRaw: UInt8

    let timeMs: UInt32
    let loopTimeMs: UInt32

    let comment: String

    let hotCueColorIndex: UInt8?
    let colorRed: UInt8?
    let colorGreen: UInt8?
    let colorBlue: UInt8?

    var slotLabel: String {
        if hotCueNumber == 0 {
            return "Memory"
        }

        return String(
            format: "HC%02d",
            Int(hotCueNumber)
        )
    }

    var cueTypeName: String {
        switch cueTypeRaw {
        case 1:
            return "Cue"
        case 2:
            return "Loop"
        default:
            return LF("未知类型 %d", cueTypeRaw)
        }
    }

    var isLoop: Bool {
        cueTypeRaw == 2
    }

    var colorDescription: String {
        guard let red = colorRed,
              let green = colorGreen,
              let blue = colorBlue else {
            return L("颜色未知")
        }

        let rgb = String(
            format: "#%02X%02X%02X",
            red,
            green,
            blue
        )

        if let index = hotCueColorIndex {
            return LF("%@ · 索引 %d", rgb, index)
        }

        return rgb
    }
}

// MARK: - 一个 PCO2 区块

struct Pco2SectionReport: Identifiable {
    var id: Int {
        offset
    }

    let offset: Int
    let headerLength: Int?
    let totalLength: Int?

    let listTypeRaw: UInt32?
    let declaredCueCount: Int?

    let cues: [Pco2CueReport]
    let parseError: String?

    var listTypeName: String {
        guard let listTypeRaw else {
            return L("无法识别")
        }

        switch listTypeRaw {
        case 0:
            return L("Memory Cue 列表")
        case 1:
            return L("Hot Cue 列表")
        default:
            return LF("未知列表类型 %d", listTypeRaw)
        }
    }
}

// MARK: - 单个 ANLZ 文件

struct AnlzFileReport: Identifiable {
    var id: String {
        relativePath
    }

    let relativePath: String
    let fileExtension: String
    let fileSize: Int
    let hasPMAIHeader: Bool

    let pco2Sections: [Pco2SectionReport]

    var pco2Offsets: [Int] {
        pco2Sections.map(\.offset)
    }

    var pco2Count: Int {
        pco2Sections.count
    }
}

struct DatabaseTrackHotCueReport: Identifiable {
    let contentID: Int64
    let title: String
    let audioPath: String
    let analysisDataFilePath: String
    let extendedAnalysisPath: String
    let hotCues: [Pco2CueReport]
    let existingMemoryCueCount: Int
    let generatedMemoryCueCount: Int
    let conversionSkipReason: String?

    var id: Int64 { contentID }
    var isProcessable: Bool { generatedMemoryCueCount > 0 && conversionSkipReason == nil }
}

struct DatabasePlaylistNode: Identifiable {
    let id: Int64
    let name: String
    let trackIDs: [Int64]
    let children: [DatabasePlaylistNode]
    let allTrackIDs: Set<Int64>
}

// MARK: - 扫描汇总

struct ScanSummary {
    let rootPath: String
    let databasePath: String
    let databaseExists: Bool
    let databaseCueRowCount: Int?
    let databaseReadError: String?
    let databaseFallbackMessage: String?
    let databaseTracks: [DatabaseTrackHotCueReport]
    let databasePlaylists: [DatabasePlaylistNode]

    let scannedFileCount: Int
    let filesContainingPCO2: Int
    let totalPCO2Sections: Int

    let files: [AnlzFileReport]

    var pco2Files: [AnlzFileReport] {
        files.filter {
            $0.pco2Count > 0
        }
    }
}

// MARK: - 错误

enum AnlzScanError: LocalizedError {
    case usbAnlzNotFound(String)
    case cannotReadDirectory(String)
    case cannotReadFile(String, String)

    var errorDescription: String? {
        switch self {
        case .usbAnlzNotFound(let path):
            return """
            没有找到 USBANLZ 目录：

            \(path)

            请确认选择的是U盘根目录，而不是 PIONEER 文件夹。
            """

        case .cannotReadDirectory(let path):
            return LF("无法读取目录：%@", path)

        case .cannotReadFile(let path, let reason):
            return """
            无法读取文件：

            \(path)

            原因：\(reason)
            """
        }
    }
}

// MARK: - 扫描器

final class AnlzScanner {

    private let pmaiMagic = Data("PMAI".utf8)
    private let pco2Magic = Data("PCO2".utf8)
    private let databaseReader = OneLibraryDatabaseReader()

    func scan(
        rootURL: URL,
        progress: ((Int, String) -> Void)? = nil
    ) throws -> ScanSummary {
        let fileManager = FileManager.default

        let pioneerURL = rootURL
            .appendingPathComponent(
                "PIONEER",
                isDirectory: true
            )

        let databaseURL = pioneerURL
            .appendingPathComponent(
                "rekordbox",
                isDirectory: true
            )
            .appendingPathComponent(
                "exportLibrary.db",
                isDirectory: false
            )

        let usbAnlzURL = pioneerURL
            .appendingPathComponent(
                "USBANLZ",
                isDirectory: true
            )

        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(
            atPath: usbAnlzURL.path,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue else {
            throw AnlzScanError.usbAnlzNotFound(
                usbAnlzURL.path
            )
        }

        var reports: [AnlzFileReport] = []
        var pendingDirectories: [URL] = [usbAnlzURL]

        while let directoryURL =
            pendingDirectories.popLast() {

            let children: [URL]

            do {
                children = try fileManager
                    .contentsOfDirectory(
                        at: directoryURL,
                        includingPropertiesForKeys: [
                            .isDirectoryKey,
                            .isRegularFileKey
                        ],
                        options: [.skipsHiddenFiles]
                    )
            } catch {
                throw AnlzScanError
                    .cannotReadDirectory(
                        directoryURL.path
                    )
            }

            for fileURL in children {
                let values =
                    try fileURL.resourceValues(
                        forKeys: [
                            .isDirectoryKey,
                            .isRegularFileKey
                        ]
                    )

                if values.isDirectory == true {
                    pendingDirectories.append(fileURL)
                    continue
                }

                guard values.isRegularFile == true else {
                    continue
                }

                let fileExtension =
                    fileURL.pathExtension.uppercased()

                guard ["DAT", "EXT", "2EX"]
                    .contains(fileExtension) else {
                    continue
                }

                let data: Data

                do {
                    data = try Data(
                        contentsOf: fileURL,
                        options: [.mappedIfSafe]
                    )
                } catch {
                    throw AnlzScanError.cannotReadFile(
                        fileURL.path,
                        error.localizedDescription
                    )
                }

                let pco2Offsets = allOffsets(
                    of: pco2Magic,
                    in: data
                )

                let pco2Sections =
                    pco2Offsets.map {
                        parsePCO2(
                            data: data,
                            offset: $0
                        )
                    }

                let relativePath = makeRelativePath(
                    fileURL: fileURL,
                    rootURL: rootURL
                )

                reports.append(
                    AnlzFileReport(
                        relativePath: relativePath,
                        fileExtension: fileExtension,
                        fileSize: data.count,
                        hasPMAIHeader:
                            data.starts(
                                with: pmaiMagic
                            ),
                        pco2Sections: pco2Sections
                    )
                )
                progress?(reports.count, relativePath)
            }
        }

        reports.sort {
            if ($0.pco2Count > 0) !=
                ($1.pco2Count > 0) {

                return $0.pco2Count > 0
            }

            return $0.relativePath
                .localizedStandardCompare(
                    $1.relativePath
                ) == .orderedAscending
        }

        let databaseExists =
            fileManager.fileExists(
                atPath: databaseURL.path
            )
        if databaseExists {
            progress?(reports.count, L("ANLZ 扫描完成，正在读取 Playlist 数据库……"))
        }

        var databaseCueRowCount: Int?
        var databaseReadError: String?
        var databaseFallbackMessage: String?
        var databaseTracks: [DatabaseTrackHotCueReport] = []
        var databasePlaylists: [DatabasePlaylistNode] = []
        if databaseExists {
            do {
                let catalog = try databaseReader.read(databaseURL: databaseURL)
                databaseCueRowCount = catalog.cueRowCount
                let reportsByPath = Dictionary(uniqueKeysWithValues: reports.map { ($0.relativePath, $0) })
                databaseTracks = catalog.tracks.map { track in
                    let extPath = (track.analysisDataFilePath as NSString)
                        .deletingPathExtension + ".EXT"
                    let normalized = extPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let report = reportsByPath[normalized]
                    let hotCues = report?.pco2Sections
                        .filter { $0.listTypeRaw == 1 }
                        .flatMap(\.cues)
                        .filter { $0.hotCueNumber > 0 }
                        .sorted { $0.hotCueNumber < $1.hotCueNumber } ?? []
                    let plan = report?.replacementPlan
                    return DatabaseTrackHotCueReport(
                        contentID: track.contentID,
                        title: track.title,
                        audioPath: track.audioPath,
                        analysisDataFilePath: track.analysisDataFilePath,
                        extendedAnalysisPath: "/" + normalized,
                        hotCues: hotCues,
                        existingMemoryCueCount: plan?.existingMemoryCues.count ?? 0,
                        generatedMemoryCueCount: plan?.generatedMemoryCueCount ?? 0,
                        conversionSkipReason: plan?.skipReason
                    )
                }
                databasePlaylists = makePlaylistTree(catalog.playlists)
            } catch {
                databaseReadError = error.localizedDescription
                databaseFallbackMessage = L("数据库目录读取组件当前不可用；已直接从 ANLZ 显示 Hot Cue。")
                let audioTitle = singleAudioTitle(in: rootURL)
                databaseTracks = reports
                    .filter { $0.fileExtension == "EXT" && !$0.allHotCues.isEmpty }
                    .enumerated()
                    .map { index, report in
                        DatabaseTrackHotCueReport(
                            contentID: -Int64(index + 1),
                            title: audioTitle ?? (report.relativePath as NSString).lastPathComponent,
                            audioPath: "",
                            analysisDataFilePath: report.relativePath,
                            extendedAnalysisPath: "/" + report.relativePath,
                            hotCues: report.allHotCues,
                            existingMemoryCueCount: report.memoryCues.count,
                            generatedMemoryCueCount: report.replacementPlan.generatedMemoryCueCount,
                            conversionSkipReason: report.replacementPlan.skipReason
                        )
                    }
                if !databaseTracks.isEmpty {
                    databasePlaylists = [DatabasePlaylistNode(
                        id: -1,
                        name: L("全部 ANLZ 曲目"),
                        trackIDs: databaseTracks.map(\.contentID),
                        children: [],
                        allTrackIDs: Set(databaseTracks.map(\.contentID))
                    )]
                }
            }
        }

        let filesContainingPCO2 =
            reports.filter {
                $0.pco2Count > 0
            }.count

        let totalPCO2Sections =
            reports.reduce(0) {
                $0 + $1.pco2Count
            }

        return ScanSummary(
            rootPath: rootURL.path,
            databasePath: databaseURL.path,
            databaseExists: databaseExists,
            databaseCueRowCount: databaseCueRowCount,
            databaseReadError: databaseReadError,
            databaseFallbackMessage: databaseFallbackMessage,
            databaseTracks: databaseTracks,
            databasePlaylists: databasePlaylists,
            scannedFileCount: reports.count,
            filesContainingPCO2:
                filesContainingPCO2,
            totalPCO2Sections:
                totalPCO2Sections,
            files: reports
        )
    }

    private func makePlaylistTree(_ records: [OneLibraryPlaylistRecord]) -> [DatabasePlaylistNode] {
        let grouped = Dictionary(grouping: records, by: \.parentPlaylistID)
        func nodes(parentID: Int64, visited: Set<Int64>) -> [DatabasePlaylistNode] {
            (grouped[parentID] ?? [])
                .filter { !visited.contains($0.playlistID) }
                .sorted {
                    if $0.sequenceNumber != $1.sequenceNumber { return $0.sequenceNumber < $1.sequenceNumber }
                    return $0.playlistID < $1.playlistID
                }
                .map { record in
                    let children = nodes(parentID: record.playlistID, visited: visited.union([record.playlistID]))
                    let allTrackIDs = children.reduce(into: Set(record.contentIDs)) {
                        $0.formUnion($1.allTrackIDs)
                    }
                    return DatabasePlaylistNode(
                        id: record.playlistID,
                        name: record.name,
                        trackIDs: record.contentIDs,
                        children: children,
                        allTrackIDs: allTrackIDs
                    )
                }
        }
        return nodes(parentID: 0, visited: [])
    }

    private func singleAudioTitle(in rootURL: URL) -> String? {
        let contents = rootURL.appendingPathComponent("Contents", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: contents,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var titles: [String] = []
        for case let fileURL as URL in enumerator {
            guard ["flac", "mp3", "wav", "aiff", "aif"].contains(fileURL.pathExtension.lowercased()) else {
                continue
            }
            titles.append(fileURL.deletingPathExtension().lastPathComponent)
            if titles.count > 1 { return nil }
        }
        return titles.first
    }

    // MARK: - PCO2解析

    private func parsePCO2(
        data: Data,
        offset: Int
    ) -> Pco2SectionReport {

        guard ascii4(
            data,
            at: offset
        ) == "PCO2" else {
            return invalidSection(
                offset: offset,
                message: L("区块开头不是 PCO2。")
            )
        }

        guard let headerLengthRaw =
                readUInt32BE(
                    data,
                    at: offset + 4
                ),
              let totalLengthRaw =
                readUInt32BE(
                    data,
                    at: offset + 8
                ),
              let listType =
                readUInt32BE(
                    data,
                    at: offset + 12
                ),
              let cueCountRaw =
                readUInt16BE(
                    data,
                    at: offset + 16
                ) else {

            return invalidSection(
                offset: offset,
                message: L("PCO2头部长度不足。")
            )
        }

        let headerLength =
            Int(headerLengthRaw)

        let totalLength =
            Int(totalLengthRaw)

        let cueCount =
            Int(cueCountRaw)

        guard headerLength >= 20 else {
            return invalidSection(
                offset: offset,
                headerLength: headerLength,
                totalLength: totalLength,
                listTypeRaw: listType,
                declaredCueCount: cueCount,
                message:
                    L("PCO2 headerLength 小于20。")
            )
        }

        guard totalLength >= headerLength else {
            return invalidSection(
                offset: offset,
                headerLength: headerLength,
                totalLength: totalLength,
                listTypeRaw: listType,
                declaredCueCount: cueCount,
                message:
                    L("PCO2 totalLength 小于 headerLength。")
            )
        }

        let sectionEnd = offset + totalLength

        guard sectionEnd <= data.count else {
            return invalidSection(
                offset: offset,
                headerLength: headerLength,
                totalLength: totalLength,
                listTypeRaw: listType,
                declaredCueCount: cueCount,
                message:
                    L("PCO2区块超出文件边界。")
            )
        }

        var cursor = offset + headerLength
        var cues: [Pco2CueReport] = []
        var parseError: String?

        for cueIndex in 0..<cueCount {
            guard cursor + 12 <= sectionEnd else {
                parseError =
                    LF("第 %lld 个Cue头部超出PCO2边界。", cueIndex + 1)
                break
            }

            guard ascii4(
                data,
                at: cursor
            ) == "PCP2" else {
                parseError = """
                第 \(cueIndex + 1) 个Cue没有找到PCP2标记。
                实际字节位置：\(cursor)
                """
                break
            }

            guard let entryHeaderLengthRaw =
                    readUInt32BE(
                        data,
                        at: cursor + 4
                    ),
                  let entryLengthRaw =
                    readUInt32BE(
                        data,
                        at: cursor + 8
                    ) else {

                parseError =
                    LF("无法读取第 %lld 个PCP2长度。", cueIndex + 1)
                break
            }

            let entryHeaderLength =
                Int(entryHeaderLengthRaw)

            let entryLength =
                Int(entryLengthRaw)

            guard entryHeaderLength >= 16 else {
                parseError = """
                第 \(cueIndex + 1) 个PCP2头部长度异常：
                \(entryHeaderLength)
                """
                break
            }

            guard entryLength >= 28 else {
                parseError = """
                第 \(cueIndex + 1) 个PCP2总长度过短：
                \(entryLength)
                """
                break
            }

            let entryEnd = cursor + entryLength

            guard entryEnd <= sectionEnd else {
                parseError = """
                第 \(cueIndex + 1) 个PCP2超出PCO2边界。
                """
                break
            }

            guard let hotCueNumber =
                    readUInt32BE(
                        data,
                        at: cursor + 12
                    ),
                  let cueType =
                    readUInt8(
                        data,
                        at: cursor + 16
                    ),
                  let timeMs =
                    readUInt32BE(
                        data,
                        at: cursor + 20
                    ),
                  let loopTimeMs =
                    readUInt32BE(
                        data,
                        at: cursor + 24
                    ) else {

                parseError =
                    LF("第 %lld 个PCP2基本字段读取失败。", cueIndex + 1)
                break
            }

            var comment = ""
            var colorIndex: UInt8?
            var red: UInt8?
            var green: UInt8?
            var blue: UInt8?

            // 标准PCP2中，comment长度位于+40。
            if cursor + 44 <= entryEnd,
               let commentLengthRaw =
                    readUInt32BE(
                        data,
                        at: cursor + 40
                    ) {

                let commentLength =
                    Int(commentLengthRaw)

                let commentStart =
                    cursor + 44

                let commentEnd =
                    commentStart + commentLength

                if commentLength >= 0,
                   commentEnd <= entryEnd {

                    comment = decodeUTF16BE(
                        data,
                        start: commentStart,
                        byteCount: commentLength
                    )

                    // 备注之后紧接Hot Cue颜色索引和RGB。
                    if commentEnd + 4 <= entryEnd {
                        colorIndex =
                            readUInt8(
                                data,
                                at: commentEnd
                            )

                        red =
                            readUInt8(
                                data,
                                at: commentEnd + 1
                            )

                        green =
                            readUInt8(
                                data,
                                at: commentEnd + 2
                            )

                        blue =
                            readUInt8(
                                data,
                                at: commentEnd + 3
                            )
                    }
                }
            }

            cues.append(
                Pco2CueReport(
                    entryOffset: cursor,
                    entryLength: entryLength,
                    hotCueNumber: hotCueNumber,
                    cueTypeRaw: cueType,
                    timeMs: timeMs,
                    loopTimeMs: loopTimeMs,
                    comment: comment,
                    hotCueColorIndex: colorIndex,
                    colorRed: red,
                    colorGreen: green,
                    colorBlue: blue
                )
            )

            cursor = entryEnd
        }

        return Pco2SectionReport(
            offset: offset,
            headerLength: headerLength,
            totalLength: totalLength,
            listTypeRaw: listType,
            declaredCueCount: cueCount,
            cues: cues,
            parseError: parseError
        )
    }

    private func invalidSection(
        offset: Int,
        headerLength: Int? = nil,
        totalLength: Int? = nil,
        listTypeRaw: UInt32? = nil,
        declaredCueCount: Int? = nil,
        message: String
    ) -> Pco2SectionReport {

        Pco2SectionReport(
            offset: offset,
            headerLength: headerLength,
            totalLength: totalLength,
            listTypeRaw: listTypeRaw,
            declaredCueCount:
                declaredCueCount,
            cues: [],
            parseError: message
        )
    }

    // MARK: - 二进制读取

    private func readUInt8(
        _ data: Data,
        at offset: Int
    ) -> UInt8? {

        guard offset >= 0,
              offset < data.count else {
            return nil
        }

        return data[
            data.index(
                data.startIndex,
                offsetBy: offset
            )
        ]
    }

    private func readUInt16BE(
        _ data: Data,
        at offset: Int
    ) -> UInt16? {

        guard let b0 =
                readUInt8(
                    data,
                    at: offset
                ),
              let b1 =
                readUInt8(
                    data,
                    at: offset + 1
                ) else {
            return nil
        }

        return
            (UInt16(b0) << 8) |
            UInt16(b1)
    }

    private func readUInt32BE(
        _ data: Data,
        at offset: Int
    ) -> UInt32? {

        guard let b0 =
                readUInt8(
                    data,
                    at: offset
                ),
              let b1 =
                readUInt8(
                    data,
                    at: offset + 1
                ),
              let b2 =
                readUInt8(
                    data,
                    at: offset + 2
                ),
              let b3 =
                readUInt8(
                    data,
                    at: offset + 3
                ) else {
            return nil
        }

        return
            (UInt32(b0) << 24) |
            (UInt32(b1) << 16) |
            (UInt32(b2) << 8) |
            UInt32(b3)
    }

    private func ascii4(
        _ data: Data,
        at offset: Int
    ) -> String? {

        guard offset >= 0,
              offset + 4 <= data.count else {
            return nil
        }

        let bytes =
            (0..<4).compactMap {
                readUInt8(
                    data,
                    at: offset + $0
                )
            }

        guard bytes.count == 4 else {
            return nil
        }

        return String(
            bytes: bytes,
            encoding: .ascii
        )
    }

    private func decodeUTF16BE(
        _ data: Data,
        start: Int,
        byteCount: Int
    ) -> String {

        guard byteCount > 0,
              byteCount % 2 == 0,
              start >= 0,
              start + byteCount <= data.count else {
            return ""
        }

        var codeUnits: [UInt16] = []

        var position = start
        let end = start + byteCount

        while position + 1 < end {
            guard let value =
                    readUInt16BE(
                        data,
                        at: position
                    ) else {
                break
            }

            codeUnits.append(value)
            position += 2
        }

        while codeUnits.last == 0 {
            codeUnits.removeLast()
        }

        return String(
            decoding: codeUnits,
            as: UTF16.self
        )
    }

    // MARK: - 通用扫描

    private func allOffsets(
        of needle: Data,
        in haystack: Data
    ) -> [Int] {

        guard !needle.isEmpty,
              haystack.count >= needle.count else {
            return []
        }

        var offsets: [Int] = []
        var searchStart =
            haystack.startIndex

        while searchStart < haystack.endIndex {
            let searchRange = searchStart..<haystack.endIndex

            guard
              let range =
                haystack.range(
                    of: needle,
                    options: [],
                    in: searchRange
                )
            else {
                break
            }

            let offset =
                haystack.distance(
                    from: haystack.startIndex,
                    to: range.lowerBound
                )

            offsets.append(offset)
            searchStart = range.upperBound
        }

        return offsets
    }

    private func makeRelativePath(
        fileURL: URL,
        rootURL: URL
    ) -> String {

        let rootPath =
            rootURL.standardizedFileURL.path

        let filePath =
            fileURL.standardizedFileURL.path

        let prefix =
            rootPath.hasSuffix("/")
            ? rootPath
            : rootPath + "/"

        if filePath.hasPrefix(prefix) {
            return String(
                filePath.dropFirst(
                    prefix.count
                )
            )
        }

        return filePath
    }
}
