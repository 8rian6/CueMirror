import SwiftUI

struct ContentView: View {
    @StateObject private var model = CueMirrorViewModel()
    @State private var expandedPlaylistIDs: Set<Int64> = []
    @State private var expandedTrackIDs: Set<Int64> = []

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
                Text("OneLibrary HC09–HC16 → Memory Cue")
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
                Label("CueMirror 还在测试阶段，请自行备份 U 盘数据", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if model.summary != nil {
                HStack(spacing: 10) {
                    Label("1  清除当前全部 Memory Cue", systemImage: "trash")
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    Label("2  HC09–HC16 转为 Memory Cue", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Button("修改并覆盖 U 盘") { model.writeReplacementToUSB() }
                        .buttonStyle(.borderedProminent)
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
                        Text("已扫描 \(model.scannedFileCount) 个 ANLZ 文件")
                        Spacer()
                        Text(model.currentScanPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        Text("数据库 cue 行：\(count)")
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
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button {
                            model.toggleAllPlaylists()
                        } label: {
                            Label("全选所有 Playlist", systemImage: allPlaylistsSelected(summary) ? "checkmark.square.fill" : "square")
                        }
                        Text("已选择 \(model.selectedTrackIDs.count) 首")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Divider()
                    ForEach(summary.databasePlaylists) { playlist in
                        playlistNodeView(playlist, tracksByID: tracksByID, depth: 0)
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
        AnyView(
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
                            Image(systemName: expandedPlaylistIDs.contains(playlist.id) ? "chevron.down" : "chevron.right")
                                .frame(width: 12)
                            Image(systemName: "music.note.list")
                            Text(playlist.name).fontWeight(.semibold)
                            Text("\(playlist.allTrackIDs.count) 首")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if expandedPlaylistIDs.contains(playlist.id) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(playlist.trackIDs, id: \.self) { id in
                            if let track = tracksByID[id] {
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
                                Text("Hot Cue \(track.hotCues.count)")
                                Text("旧 Memory \(track.existingMemoryCueCount)")
                                Text("将生成 \(track.generatedMemoryCueCount)")
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
                }
                .padding(.leading, 28)
            }
        }
    }

    private func hotCueRow(_ cue: Pco2CueReport) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: cue.isLoop ? "repeat.circle.fill" : "mappin.circle.fill")
                .foregroundStyle(cue.isLoop ? .orange : .green)
            VStack(alignment: .leading, spacing: 4) {
                Text(cue.slotLabel).fontWeight(.semibold)
                Text("时间 \(formatMilliseconds(cue.timeMs)) · \(cue.cueTypeName)")
                if cue.isLoop {
                    Text("Loop 终点 \(formatMilliseconds(cue.loopTimeMs))")
                }
                if !cue.comment.isEmpty { Text("评论：\(cue.comment)") }
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
                                Text("将删除旧 Memory：\(report.replacementPlan.deletedMemoryCueCount)")
                                Text("HC09–16：\(report.memoryCueCandidates.count)")
                                Text("将生成：\(report.projectedMemoryCueCount)")
                                if report.hasCapacityConflict {
                                    Label(report.replacementPlan.skipReason ?? L("存在冲突"), systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                                if report.parseErrorCount > 0 {
                                    Text("解析错误：\(report.parseErrorCount)").foregroundStyle(.red)
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
                Text("时间 \(formatMilliseconds(candidate.sourceCue.timeMs)) · \(candidate.sourceCue.cueTypeName)")
                if candidate.sourceCue.isLoop {
                    Text("Loop 终点 \(formatMilliseconds(candidate.sourceCue.loopTimeMs))")
                }
                if !candidate.sourceCue.comment.isEmpty { Text("评论：\(candidate.sourceCue.comment)") }
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
                .accessibilityLabel("颜色 \(cue.colorDescription)")
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
