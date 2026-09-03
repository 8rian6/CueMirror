import AppKit
import Foundation

@MainActor
final class CueMirrorViewModel: ObservableObject {

    private static let defaultActiveLoopKey = "defaultActiveMemoryLoopSlot"

    @Published var selectedDriveName =
        L("尚未选择U盘")

    @Published var statusMessage =
        L("请选择 OneLibrary U盘根目录。")

    @Published var summary: ScanSummary?

    @Published var errorMessage: String?
    @Published var conversionMessage: String?
    @Published var selectedTrackIDs: Set<Int64> = []
    @Published var isScanning = false
    @Published var scannedFileCount = 0
    @Published var currentScanPath = ""
    @Published var scanStartedAt: Date?
    @Published var isConverting = false
    @Published var conversionProcessedCount = 0
    @Published var conversionTotalCount = 0
    @Published var currentConversionTrack = ""
    @Published var conversionPhase = ""
    @Published var conversionStartedAt: Date?
    @Published var defaultActiveLoopSlot: Int {
        didSet { UserDefaults.standard.set(defaultActiveLoopSlot, forKey: Self.defaultActiveLoopKey) }
    }
    /// -1 = 跟随全局，0 = 不激活，1...8 = Saved Loop 槽位。
    @Published var trackActiveLoopOverrides: [Int64: Int] = [:]
    private let scanner = AnlzScanner()
    private let replacementWriter = HotCueMemoryReplacementWriter()
    private var selectedRootURL: URL?

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.defaultActiveLoopKey) as? Int
        defaultActiveLoopSlot = stored.map { min(8, max(0, $0)) } ?? 2
    }

    func activeLoopChoice(for trackID: Int64) -> Int {
        trackActiveLoopOverrides[trackID] ?? -1
    }

    func setActiveLoopChoice(_ choice: Int, for trackID: Int64) {
        if choice == -1 { trackActiveLoopOverrides.removeValue(forKey: trackID) }
        else { trackActiveLoopOverrides[trackID] = choice }
    }

    func resolvedActiveLoopSlot(for trackID: Int64) -> Int? {
        let choice = activeLoopChoice(for: trackID)
        let resolved = choice == -1 ? defaultActiveLoopSlot : choice
        return resolved == 0 ? nil : resolved
    }

    func chooseAndScan() {
        let panel = NSOpenPanel()

        panel.title = L("选择 OneLibrary U盘")
        panel.message = L("请选择U盘根目录。\n不要进入 PIONEER 或 USBANLZ 文件夹。")

        panel.prompt = L("选择并扫描")

        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK,
              let rootURL = panel.url else {
            return
        }

        selectedDriveName =
            rootURL.lastPathComponent
        selectedRootURL = rootURL

        summary = nil
        errorMessage = nil
        conversionMessage = nil
        isScanning = true
        scanStartedAt = Date()
        scannedFileCount = 0
        currentScanPath = L("正在枚举 USBANLZ 文件……")
        statusMessage = L("正在只读扫描……")

        let startedSecurityAccess =
            rootURL.startAccessingSecurityScopedResource()
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try AnlzScanner().scan(rootURL: rootURL) { count, path in
                        Task { @MainActor [weak self] in
                            self?.scannedFileCount = count
                            self?.currentScanPath = path
                        }
                    }
                }.value
                summary = result
                selectedTrackIDs = []
                statusMessage = L("扫描完成。没有修改U盘中的任何文件。")
            } catch {
                summary = nil
                errorMessage = error.localizedDescription
                statusMessage = L("扫描失败。")
            }
            isScanning = false
            scanStartedAt = nil
            currentScanPath = ""
            if startedSecurityAccess { rootURL.stopAccessingSecurityScopedResource() }
        }
    }

    func toggleTrack(_ id: Int64) {
        if selectedTrackIDs.contains(id) { selectedTrackIDs.remove(id) }
        else { selectedTrackIDs.insert(id) }
    }

    func setTrack(_ id: Int64, selected: Bool) {
        if selected { selectedTrackIDs.insert(id) }
        else { selectedTrackIDs.remove(id) }
    }

    func togglePlaylist(_ playlist: DatabasePlaylistNode) {
        let ids = playlist.allTrackIDs
        if ids.isSubset(of: selectedTrackIDs) { selectedTrackIDs.subtract(ids) }
        else { selectedTrackIDs.formUnion(ids) }
    }

    func setPlaylist(_ playlist: DatabasePlaylistNode, selected: Bool) {
        if selected { selectedTrackIDs.formUnion(playlist.allTrackIDs) }
        else { selectedTrackIDs.subtract(playlist.allTrackIDs) }
    }

    func toggleAllPlaylists() {
        guard let summary else { return }
        let ids = summary.databasePlaylists.reduce(into: Set<Int64>()) { $0.formUnion($1.allTrackIDs) }
        if ids.isSubset(of: selectedTrackIDs) { selectedTrackIDs.subtract(ids) }
        else { selectedTrackIDs.formUnion(ids) }
    }

    func isPlaylistSelected(_ playlist: DatabasePlaylistNode) -> Bool {
        !playlist.allTrackIDs.isEmpty && playlist.allTrackIDs.isSubset(of: selectedTrackIDs)
    }

    func writeReplacementToUSB() {
        guard let rootURL = selectedRootURL, let summary else {
            errorMessage = L("请先选择并扫描 OneLibrary U盘。")
            return
        }
        let selectedTracks = summary.databaseTracks.filter { selectedTrackIDs.contains($0.contentID) }
        guard !selectedTracks.isEmpty else {
            presentWriteError(L("请先在播放列表中选择至少一首曲目。"))
            return
        }

        // Confirm before doing potentially slow audio/ANLZ preparation. Previously the
        // confirmation appeared only after preparation succeeded, so a preparation
        // failure looked like an unresponsive button when its inline error was offscreen.
        let confirmation = NSAlert()
        confirmation.alertStyle = .critical
        confirmation.messageText = L("覆盖 U 盘中的 Memory Cue 和 Memory Loop？")
        confirmation.informativeText = LF(
            "已选择 %lld 首。确认后将先准备转换数据；只会写入可成功准备的曲目。HC01–HC08 保持不变，HC09–HC16 复制为 Memory Cue，djay Saved Loop 转换为 Memory Loop。",
            selectedTracks.count
        )
        confirmation.addButton(withTitle: LF("继续处理 %lld 首曲目", selectedTracks.count))
        confirmation.addButton(withTitle: L("取消"))
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        let activeSlots = Dictionary(uniqueKeysWithValues: selectedTracks.map {
            ($0.contentID, resolvedActiveLoopSlot(for: $0.contentID))
        })
        let rootAccess = rootURL.startAccessingSecurityScopedResource()
        isConverting = true
        conversionProcessedCount = 0
        conversionTotalCount = selectedTracks.count
        currentConversionTrack = ""
        conversionPhase = L("正在准备转换数据……")
        conversionStartedAt = Date()
        errorMessage = nil
        conversionMessage = nil

        Task {
            defer {
                isConverting = false
                conversionStartedAt = nil
                currentConversionTrack = ""
                if rootAccess { rootURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let batch = try await Task.detached(priority: .userInitiated) {
                    try Self.prepare(
                        tracks: selectedTracks,
                        activeSlots: activeSlots,
                        rootURL: rootURL
                    ) { completed, title in
                        Task { @MainActor [weak self] in
                            self?.conversionProcessedCount = completed
                            self?.currentConversionTrack = title
                        }
                    }
                }.value
                guard !batch.items.isEmpty else {
                    throw HotCueMemoryReplacementError.unsupportedCue(
                        L("所选曲目均无法处理。") + "\n" + batch.skipped.joined(separator: "\n")
                    )
                }

                conversionPhase = L("正在写入并回读验证 U 盘……")
                conversionProcessedCount = 0
                conversionTotalCount = batch.items.count
                let completed = try await Task.detached(priority: .userInitiated) {
                    var count = 0
                    for item in batch.items {
                        let reportedCount = count
                        Task { @MainActor [weak self] in
                            self?.currentConversionTrack = item.title
                            self?.conversionProcessedCount = reportedCount
                        }
                        try item.result.datData.write(to: item.datURL, options: .atomic)
                        try item.result.extData.write(to: item.extURL, options: .atomic)
                        guard try Data(contentsOf: item.datURL, options: .mappedIfSafe) == item.result.datData,
                              try Data(contentsOf: item.extURL, options: .mappedIfSafe) == item.result.extData else {
                            throw HotCueMemoryReplacementError.verificationFailed(
                                LF("%@ 的 U 盘正式文件回读不一致", item.title)
                            )
                        }
                        count += 1
                    }
                    return count
                }.value

                conversionPhase = L("正在重新扫描写入结果……")
                conversionProcessedCount = completed
                let refreshed = try await Task.detached(priority: .userInitiated) {
                    try AnlzScanner().scan(rootURL: rootURL)
                }.value
                self.summary = refreshed
                selectedTrackIDs = []
                conversionMessage = LF(
                    "批量写入成功：%lld 首；删除旧 Memory %lld 条；生成新 Memory %lld 条；跳过 %lld 首。",
                    completed, batch.deletedCount, batch.generatedCount, batch.skipped.count
                )
                errorMessage = nil
            } catch {
                conversionMessage = nil
                presentWriteError(error.localizedDescription)
            }
        }
    }

    private func presentWriteError(_ message: String) {
        errorMessage = message
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("无法修改 U 盘")
        alert.informativeText = message
        alert.addButton(withTitle: L("好"))
        alert.runModal()
    }

    nonisolated private static func audioFile(for track: DatabaseTrackHotCueReport, rootURL: URL) -> URL? {
        if !track.audioPath.isEmpty {
            return rootURL.appendingPathComponent(
                track.audioPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
        }
        let contents = rootURL.appendingPathComponent("Contents", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: nil) else {
            return nil
        }
        var exact: URL?
        for case let url as URL in enumerator {
            guard ["flac", "mp3", "wav", "wave", "aiff", "aif"].contains(url.pathExtension.lowercased()) else { continue }
            if url.deletingPathExtension().lastPathComponent == track.title {
                if exact != nil { return nil }
                exact = url
            }
        }
        return exact
    }

    private struct PreparedTrackWrite {
        let title: String
        let datURL: URL
        let extURL: URL
        let result: HotCueMemoryReplacementResult
    }

    private struct PreparedBatch {
        let items: [PreparedTrackWrite]
        let skipped: [String]
        let deletedCount: Int
        let generatedCount: Int
    }

    nonisolated private static func prepare(
        tracks: [DatabaseTrackHotCueReport],
        activeSlots: [Int64: Int?],
        rootURL: URL,
        progress: @escaping (Int, String) -> Void
    ) throws -> PreparedBatch {
        var prepared: [PreparedTrackWrite] = []
        var skipped: [String] = []
        for (index, track) in tracks.enumerated() {
            progress(index, track.title)
            guard track.isProcessable else {
                skipped.append("\(track.title): \(track.conversionSkipReason ?? L("没有 HC09–HC16 或 Saved Loop"))")
                continue
            }
            guard let audioURL = audioFile(for: track, rootURL: rootURL) else {
                skipped.append("\(track.title): \(L("找不到对应的音频文件"))")
                continue
            }
            let locator: any AudioCueLocating
            switch audioURL.pathExtension.lowercased() {
            case "flac": locator = FLACAudioCueLocator()
            case "mp3": locator = MP3AudioCueLocator()
            case "wav", "wave", "aiff", "aif": locator = SystemAudioCueLocator()
            default:
                skipped.append("\(track.title): \(L("不支持的音频格式"))")
                continue
            }
            let datURL = rootURL.appendingPathComponent(
                track.analysisDataFilePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
            let extURL = rootURL.appendingPathComponent(
                track.extendedAnalysisPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
            do {
                let result = try HotCueMemoryReplacementWriter().makeOutput(
                    datData: try Data(contentsOf: datURL, options: .mappedIfSafe),
                    extData: try Data(contentsOf: extURL, options: .mappedIfSafe),
                    audioFile: audioURL,
                    savedLoops: track.savedLoops,
                    activeSavedLoopSlot: activeSlots[track.contentID] ?? nil,
                    locator: locator
                )
                prepared.append(PreparedTrackWrite(title: track.title, datURL: datURL, extURL: extURL, result: result))
            } catch {
                skipped.append("\(track.title)：\(error.localizedDescription)")
            }
            progress(index + 1, track.title)
        }
        return PreparedBatch(
            items: prepared,
            skipped: skipped,
            deletedCount: prepared.reduce(0) { $0 + $1.result.deletedMemoryCueCount },
            generatedCount: prepared.reduce(0) { $0 + $1.result.generatedMemoryCueCount }
        )
    }
}
