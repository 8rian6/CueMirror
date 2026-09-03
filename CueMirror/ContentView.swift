import SwiftUI

struct ContentView: View {
    @StateObject private var model = CueMirrorViewModel()
    @State private var expandedPlaylistIDs: Set<Int64> = []
    @State private var expandedTrackIDs: Set<Int64> = []
    @State private var searchInputText = ""
    @State private var trackSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            topOperationArea
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    statusArea
                    if let summary = model.summary {
                        summaryArea(summary)
                        Divider()
                        databaseHotCueList(summary)
                        Divider()
                        candidateFileList(summary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            }
        }
        .padding(22)
        .frame(minWidth: 1050, minHeight: 720)
    }

    private var topOperationArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("CueMirror").font(.largeTitle).fontWeight(.semibold)
                    Text(AppVersion.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L("HC09–HC16 转 Memory Cue · djay Saved Loop 转 Memory Loop · 支持 Active Loop"))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("选择 OneLibrary U盘") { model.chooseAndScan() }
                    .keyboardShortcut("o", modifiers: [.command])
                    .fixedSize()
                    .disabled(model.isScanning)
                Text(model.selectedDriveName).fontWeight(.medium).textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Picker(L("Default Active Memory Loop"), selection: $model.defaultActiveLoopSlot) {
                    Text("None").tag(0)
                    ForEach(1...8, id: \.self) { slot in
                        Text("Saved Loop \(slot)").tag(slot)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Label("CueMirror 还在测试阶段，请自行备份 U 盘数据", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if model.summary != nil {
                HStack(spacing: 10) {
                    Label(L("1  清除当前全部 Memory Cue 和 Memory Loop"), systemImage: "trash")
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    Label(L("2  从 HC09–HC16 和 Saved Loop 重建 Memory"), systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Button("修改并覆盖 U 盘") { model.writeReplacementToUSB() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isConverting)
                }
                .font(.callout)
            }
        }
    }

    private var statusArea: some View {
        GroupBox("状态") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.statusMessage).frame(maxWidth: .infinity, alignment: .leading)
                if model.isScanning {
                    ProgressView()
                        .progressViewStyle(.linear)
                    HStack {
                        Text(LF("已扫描 %lld 个 ANLZ 文件", model.scannedFileCount))
                        Spacer()
                        Text(model.currentScanPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = Int(context.date.timeIntervalSince(model.scanStartedAt ?? context.date))
                        Label(
                            LF("扫描已运行 %lld 秒 · 程序仍在响应", elapsed),
                            systemImage: "waveform.path.ecg"
                        )
                        .font(.caption)
                        .foregroundStyle(.green)
                    }
                }
                if model.isConverting {
                    ProgressView(
                        value: Double(model.conversionProcessedCount),
                        total: Double(max(model.conversionTotalCount, 1))
                    )
                    .progressViewStyle(.linear)
                    HStack {
                        Text(model.conversionPhase)
                        Spacer()
                        Text("\(model.conversionProcessedCount) / \(model.conversionTotalCount)")
                    }
                    .font(.caption)
                    if !model.currentConversionTrack.isEmpty {
                        Text(model.currentConversionTrack)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = Int(context.date.timeIntervalSince(model.conversionStartedAt ?? context.date))
                        Label(
                            LF("处理已运行 %lld 秒 · 程序仍在响应", elapsed),
                            systemImage: "waveform.path.ecg"
                        )
                        .font(.caption)
                        .foregroundStyle(.green)
                    }
                }
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let message = model.conversionMessage {
                    Text(message)
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }
            }.padding(6)
        }
    }

    private func summaryArea(_ summary: ScanSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                summaryCard(title: L("ANLZ 文件"), value: "\(summary.scannedFileCount)")
                summaryCard(title: L("含 HC09–16 文件"), value: "\(summary.filesContainingHotCues9Through16)")
                summaryCard(title: L("处理曲目 / 新 Cue"), value: "\(summary.processableTrackCount) / \(summary.generatedMemoryCueCount)")
                summaryCard(title: L("冲突 / 解析错误"), value: "\(summary.conflictFileCount) / \(summary.parseErrorCount)")
            }
            GroupBox("exportLibrary.db") {
                HStack {
                    Image(systemName: summary.databaseExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(summary.databaseExists ? Color.green : Color.red)
                    Text(summary.databaseExists ? L("已找到") : L("未找到")).fontWeight(.medium)
                    if let count = summary.databaseCueRowCount {
                        Text(LF("数据库 cue 行：%lld", count))
                            .foregroundStyle(.secondary)
                    }
                    Text(summary.databasePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                }.padding(6)
                if let message = summary.databaseFallbackMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
            }
        }
    }

    private func databaseHotCueList(_ summary: ScanSummary) -> some View {
        GroupBox {
            if summary.databasePlaylists.isEmpty {
                ContentUnavailableView(
                    "没有可显示的播放列表",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text(summary.databaseFallbackMessage ?? L("数据库没有返回播放列表记录。"))
                )
                .frame(minHeight: 150)
            } else {
                let tracksByID = Dictionary(uniqueKeysWithValues: summary.databaseTracks.map { ($0.contentID, $0) })
                let visiblePlaylists = summary.databasePlaylists.compactMap {
                    filteredPlaylist($0, tracksByID: tracksByID)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField(L("搜索曲目"), text: $searchInputText)
                            .onChange(of: searchInputText) { _, newValue in
                                scheduleSearch(for: newValue)
                            }
                        if searchInputText != trackSearchText {
                            ProgressView().controlSize(.small)
                            Text(L("等待输入完成…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button {
                            model.toggleAllPlaylists()
                        } label: {
                            Label("全选所有 Playlist", systemImage: allPlaylistsSelected(summary) ? "checkmark.square.fill" : "square")
                        }
                        Text(LF("已选择 %lld 首", model.selectedTrackIDs.count))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Divider()
                    ForEach(visiblePlaylists) { playlist in
                        playlistNodeView(playlist, tracksByID: tracksByID, depth: 0)
                    }
                    if !trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       visiblePlaylists.isEmpty {
                        ContentUnavailableView.search(text: trackSearchText)
                    }
                }
                .padding(8)
            }
        } label: {
            Text("Playlist 与曲目选择")
        }
    }

    private func allPlaylistsSelected(_ summary: ScanSummary) -> Bool {
        let ids = summary.databasePlaylists.reduce(into: Set<Int64>()) { $0.formUnion($1.allTrackIDs) }
        return !ids.isEmpty && ids.isSubset(of: model.selectedTrackIDs)
    }

    private func playlistNodeView(
        _ playlist: DatabasePlaylistNode,
        tracksByID: [Int64: DatabaseTrackHotCueReport],
        depth: Int
    ) -> AnyView {
        let searching = !trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isExpanded = searching || expandedPlaylistIDs.contains(playlist.id)
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { model.isPlaylistSelected(playlist) },
                        set: { model.setPlaylist(playlist, selected: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    Button {
                        if expandedPlaylistIDs.contains(playlist.id) {
                            expandedPlaylistIDs.remove(playlist.id)
                        } else {
                            expandedPlaylistIDs.insert(playlist.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .frame(width: 12)
                            Image(systemName: "music.note.list")
                            Text(playlist.name).fontWeight(.semibold)
                            Text(LF("%lld 首", playlist.allTrackIDs.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(playlist.trackIDs, id: \.self) { id in
                            if let track = tracksByID[id], trackMatchesSearch(track) {
                                playlistTrackRow(track)
                            }
                        }
                        ForEach(playlist.children) { child in
                            playlistNodeView(child, tracksByID: tracksByID, depth: depth + 1)
                        }
                    }
                    .padding(.leading, 28)
                    .padding(.top, 6)
                }
            }
            .padding(.leading, CGFloat(depth * 12))
        )
    }

    private func playlistTrackRow(_ track: DatabaseTrackHotCueReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { model.selectedTrackIDs.contains(track.contentID) },
                    set: { model.setTrack(track.contentID, selected: $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                Button {
                    if expandedTrackIDs.contains(track.contentID) {
                        expandedTrackIDs.remove(track.contentID)
                    } else {
                        expandedTrackIDs.insert(track.contentID)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expandedTrackIDs.contains(track.contentID) ? "chevron.down" : "chevron.right")
                            .frame(width: 12)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                            HStack(spacing: 10) {
                                Text(LF("Hot Cue %lld", track.hotCues.count))
                                Text(LF("旧 Memory %lld", track.existingMemoryCueCount))
                                Text(LF("将生成 %lld", track.generatedMemoryCueCount))
                                if let reason = track.conversionSkipReason {
                                    Text(reason).foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if expandedTrackIDs.contains(track.contentID) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.extendedAnalysisPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    ForEach(track.hotCues) { cue in hotCueRow(cue) }
                    if !track.savedLoops.isEmpty {
                        Divider()
                        Text("djay Saved Loops").font(.caption).fontWeight(.semibold)
                        ForEach(track.savedLoops) { loop in
                            HStack(spacing: 10) {
                                Image(systemName: "repeat.circle.fill").foregroundStyle(.orange)
                                Text("Saved Loop \(loop.slot)").fontWeight(.semibold)
                                Text("\(formatMilliseconds(loop.startTimeMs)) → \(formatMilliseconds(loop.endTimeMs))")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                    Picker("Active Memory Loop", selection: Binding(
                        get: { model.activeLoopChoice(for: track.contentID) },
                        set: { model.setActiveLoopChoice($0, for: track.contentID) }
                    )) {
                        Text(LF("Use Global Setting (current: %@)", activeLoopLabel(model.defaultActiveLoopSlot))).tag(-1)
                        Text("None").tag(0)
                        ForEach(savedLoopSlots(in: track), id: \.self) { slot in
                            Text("Saved Loop \(slot)").tag(slot)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .padding(.leading, 28)
            }
        }
    }

    private func activeLoopLabel(_ slot: Int) -> String {
        slot == 0 ? "None" : "Saved Loop \(slot)"
    }

    private func savedLoopSlots(in track: DatabaseTrackHotCueReport) -> [Int] {
        track.savedLoops.map(\.slot).sorted()
    }

    private func trackMatchesSearch(_ track: DatabaseTrackHotCueReport) -> Bool {
        let query = trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || track.title.localizedCaseInsensitiveContains(query)
    }

    private func scheduleSearch(for value: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            trackSearchText = value
        }
    }

    /// During search, retain only matching tracks and the ancestor playlist path
    /// needed to tell the user where each match lives.
    private func filteredPlaylist(
        _ playlist: DatabasePlaylistNode,
        tracksByID: [Int64: DatabaseTrackHotCueReport]
    ) -> DatabasePlaylistNode? {
        let query = trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return playlist }

        let matchingTrackIDs = playlist.trackIDs.filter { id in
            tracksByID[id].map(trackMatchesSearch) ?? false
        }
        let matchingChildren = playlist.children.compactMap {
            filteredPlaylist($0, tracksByID: tracksByID)
        }
        guard !matchingTrackIDs.isEmpty || !matchingChildren.isEmpty else { return nil }

        var visibleIDs = Set(matchingTrackIDs)
        for child in matchingChildren { visibleIDs.formUnion(child.allTrackIDs) }
        return DatabasePlaylistNode(
            id: playlist.id,
            name: playlist.name,
            trackIDs: matchingTrackIDs,
            children: matchingChildren,
            allTrackIDs: visibleIDs
        )
    }

    private func hotCueRow(_ cue: Pco2CueReport) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: cue.isLoop ? "repeat.circle.fill" : "mappin.circle.fill")
                .foregroundStyle(cue.isLoop ? .orange : .green)
            VStack(alignment: .leading, spacing: 4) {
                Text(cue.slotLabel).fontWeight(.semibold)
                Text(LF("时间 %@ · %@", formatMilliseconds(cue.timeMs), cue.cueTypeName))
                if cue.isLoop {
                    Text(LF("Loop 终点 %@", formatMilliseconds(cue.loopTimeMs)))
                }
                if !cue.comment.isEmpty { Text(LF("评论：%@", cue.comment)) }
                HStack(spacing: 6) {
                    colorSwatch(for: cue)
                    Text(cue.colorDescription)
                }
                .foregroundStyle(.secondary)
            }
            .font(.caption)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func summaryCard(title: String, value: String) -> some View {
        GroupBox(title) {
            Text(value).font(.title2).fontWeight(.semibold).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }.frame(maxWidth: .infinity)
    }

    private func candidateFileList(_ summary: ScanSummary) -> some View {
        GroupBox("HC09–HC16 → Memory Cue 候选") {
            if summary.candidateFiles.isEmpty {
                ContentUnavailableView(
                    "没有找到 HC09–HC16",
                    systemImage: "magnifyingglass",
                    description: Text("本次只读扫描没有修改任何文件。")
                ).frame(minHeight: 180)
            } else {
                List(summary.candidateFiles) { report in
                    DisclosureGroup {
                        ForEach(report.memoryCueCandidates) { candidate in
                            candidateRow(candidate)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(report.relativePath)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            HStack(spacing: 14) {
                                Text(LF("将删除旧 Memory：%lld", report.replacementPlan.deletedMemoryCueCount))
                                Text(LF("HC09–16：%lld", report.memoryCueCandidates.count))
                                Text(LF("将生成：%lld", report.projectedMemoryCueCount))
                                if report.hasCapacityConflict {
                                    Label(report.replacementPlan.skipReason ?? L("存在冲突"), systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                                if report.parseErrorCount > 0 {
                                    Text(LF("解析错误：%lld", report.parseErrorCount)).foregroundStyle(.red)
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }.frame(minHeight: 260)
            }
        }
    }

    private func candidateRow(_ candidate: MemoryCueCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: candidate.isConvertible ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(candidate.isConvertible ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.displayName).fontWeight(.semibold)
                Text(LF("时间 %@ · %@", formatMilliseconds(candidate.sourceCue.timeMs), candidate.sourceCue.cueTypeName))
                if candidate.sourceCue.isLoop {
                    Text(LF("Loop 终点 %@", formatMilliseconds(candidate.sourceCue.loopTimeMs)))
                }
                if !candidate.sourceCue.comment.isEmpty { Text(LF("评论：%@", candidate.sourceCue.comment)) }
                HStack(spacing: 6) {
                    colorSwatch(for: candidate.sourceCue)
                    Text(candidate.sourceCue.colorDescription)
                }
                .foregroundStyle(.secondary)
                Text(candidate.statusDescription)
                    .foregroundStyle(
                        candidate.isConvertible ? Color.secondary : Color.orange
                    )
            }.font(.caption)
            Spacer()
        }.padding(.vertical, 4)
    }

    @ViewBuilder
    private func colorSwatch(for cue: Pco2CueReport) -> some View {
        if let red = cue.colorRed, let green = cue.colorGreen, let blue = cue.colorBlue {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(
                    red: Double(red) / 255,
                    green: Double(green) / 255,
                    blue: Double(blue) / 255
                ))
                .frame(width: 18, height: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.primary.opacity(0.35), lineWidth: 1)
                }
                .accessibilityLabel(LF("颜色 %@", cue.colorDescription))
        } else {
            Image(systemName: "circle.slash")
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
                .accessibilityLabel("颜色数据缺失")
        }
    }

    private func formatMilliseconds(_ value: UInt32) -> String {
        let totalSeconds = Double(value) / 1_000
        let minutes = Int(totalSeconds) / 60
        let seconds = totalSeconds - Double(minutes * 60)
        return String(format: "%d:%06.3f", minutes, seconds)
    }
}

#Preview { ContentView() }
