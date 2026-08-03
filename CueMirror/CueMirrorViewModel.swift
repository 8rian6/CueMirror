import AppKit
import Foundation

@MainActor
final class CueMirrorViewModel: ObservableObject {

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

    private let scanner = AnlzScanner()
    private let replacementWriter = HotCueMemoryReplacementWriter()
    private var selectedRootURL: URL?

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
            errorMessage = L("请先在播放列表中选择至少一首曲目。")
            return
        }

        let rootAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if rootAccess { rootURL.stopAccessingSecurityScopedResource() }
        }
        do {
            var prepared: [PreparedTrackWrite] = []
            var skipped: [String] = []
            for track in selectedTracks {
                guard track.isProcessable else {
                    skipped.append("\(track.title): \(track.conversionSkipReason ?? L("没有 HC09–HC16"))")
                    continue
                }
                guard let audioURL = audioFile(for: track, rootURL: rootURL),
                      audioURL.pathExtension.lowercased() == "flac" else {
                    skipped.append("\(track.title): \(L("目前只支持 FLAC"))")
                    continue
                }
                let datRelative = track.analysisDataFilePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let extRelative = track.extendedAnalysisPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let datURL = rootURL.appendingPathComponent(datRelative)
                let extURL = rootURL.appendingPathComponent(extRelative)
                do {
                    let result = try replacementWriter.makeOutput(
                        datData: try Data(contentsOf: datURL, options: .mappedIfSafe),
                        extData: try Data(contentsOf: extURL, options: .mappedIfSafe),
                        audioFile: audioURL
                    )
                    prepared.append(PreparedTrackWrite(title: track.title, datURL: datURL, extURL: extURL, result: result))
                } catch {
                    skipped.append("\(track.title)：\(error.localizedDescription)")
                }
            }
            guard !prepared.isEmpty else {
                throw HotCueMemoryReplacementError.unsupportedCue(L("所选曲目均无法处理。") + "\n" + skipped.joined(separator: "\n"))
            }
            let deleted = prepared.reduce(0) { $0 + $1.result.deletedMemoryCueCount }
            let generated = prepared.reduce(0) { $0 + $1.result.generatedMemoryCueCount }
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L("覆盖 U 盘中的 Memory Cue？")
            alert.informativeText = LF("已选择 %lld 首；可写入 %lld 首，跳过 %lld 首。将删除 %lld 条旧 Memory Cue，并只把 HC09–HC16 转换为 %lld 条新 Cue。HC01–HC08 不会复制。", selectedTracks.count, prepared.count, skipped.count, deleted, generated)
            alert.addButton(withTitle: LF("覆盖 %lld 首曲目", prepared.count))
            alert.addButton(withTitle: L("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            var completed = 0
            for item in prepared {
                try item.result.datData.write(to: item.datURL, options: .atomic)
                try item.result.extData.write(to: item.extURL, options: .atomic)
                guard try Data(contentsOf: item.datURL, options: .mappedIfSafe) == item.result.datData,
                      try Data(contentsOf: item.extURL, options: .mappedIfSafe) == item.result.extData else {
                    throw HotCueMemoryReplacementError.verificationFailed("\(item.title) 的 U 盘正式文件回读不一致")
                }
                completed += 1
            }
            self.summary = try scanner.scan(rootURL: rootURL)
            selectedTrackIDs = []
            conversionMessage = LF("批量写入成功：%lld 首；删除旧 Memory %lld 条；HC09–HC16 生成 %lld 条；跳过 %lld 首。", completed, deleted, generated, skipped.count)
            errorMessage = nil
        } catch {
            conversionMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func audioFile(for track: DatabaseTrackHotCueReport, rootURL: URL) -> URL? {
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
            guard ["flac", "mp3", "wav", "aiff", "aif"].contains(url.pathExtension.lowercased()) else { continue }
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
}
