import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var manager = ConversionManager()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            jobListArea
            Divider()
            settingsBar
            Divider()
            controlBar
        }
        .frame(minWidth: 640, minHeight: 460)
        .dropDestination(for: URL.self) { urls, _ in
            manager.addFiles(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay { dropHighlight }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { manager.errorMessage != nil },
                set: { if !$0 { manager.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manager.errorMessage ?? "")
        }
    }

    // MARK: - ファイルリスト

    @ViewBuilder
    private var jobListArea: some View {
        if manager.jobs.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text("ここに mp4 をドラッグ&ドロップ")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("または下の「ファイル追加」ボタンから選択")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(manager.jobs) { job in
                JobRowView(job: job) {
                    manager.removeJob(job.id)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .background(
                    Color.accentColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 出力先・ラウドネス設定

    private var settingsBar: some View {
        HStack(spacing: 8) {
            Text("出力先")
            Text(manager.outputDirectory?.path ?? "未選択")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(manager.outputDirectory == nil ? .secondary : .primary)
                .help(manager.outputDirectory?.path ?? "出力先フォルダを選択してください")
            Button("選択...") { chooseOutputDirectory() }
                .disabled(manager.isRunning)
            Spacer()
            Picker("目標ラウドネス", selection: $manager.targetLoudness) {
                Text("-14 LUFS（ストリーミング）").tag(-14)
                Text("-16 LUFS（配信・ポッドキャスト）").tag(-16)
                Text("-18 LUFS").tag(-18)
                Text("-23 LUFS（放送 EBU R128）").tag(-23)
            }
            .fixedSize()
            .disabled(manager.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 操作ボタン・全体進捗

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                addFilesViaPanel()
            } label: {
                Label("ファイル追加", systemImage: "plus")
            }

            Spacer()

            if !manager.jobs.isEmpty {
                ProgressView(value: manager.overallProgress)
                    .frame(width: 180)
                Text("\(manager.finishedCount)/\(manager.jobs.count) 完了")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .scaleEffect(manager.allFinished ? 1.15 : 1)
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.45),
                        value: manager.allFinished
                    )
            }

            Spacer()

            Button(manager.startButtonLabel) { manager.start() }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isRunning || !manager.hasQueuedJobs)

            Button("中止") { manager.cancel() }
                .disabled(!manager.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - パネル

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "出力先に設定"
        if panel.runModal() == .OK, let url = panel.url {
            manager.outputDirectory = url
        }
    }

    private func addFilesViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ConversionManager.allowedExtensions
            .compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            manager.addFiles(panel.urls)
        }
    }
}

// MARK: - リスト行

struct JobRowView: View {
    let job: ConversionJob
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(job.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(job.sourceURL.path)
                .frame(maxWidth: .infinity, alignment: .leading)

            StatusBadge(status: job.status)

            progressColumn
                .frame(width: 150, alignment: .leading)

            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(job.status.isActive)
            .opacity(job.status.isActive ? 0.3 : 1)
            .help(job.status.isActive ? "処理中は削除できません" : "リストから削除（出力ファイルは消しません）")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var progressColumn: some View {
        switch job.status {
        case .analyzing, .converting, .done:
            HStack(spacing: 6) {
                ProgressView(value: job.status.progress)
                Text("\(Int(job.status.progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        default:
            Text("-")
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 状態バッジ（パステル背景のpill型チップ / 仕様書 4.2.1）

struct StatusBadge: View {
    let status: ConversionStatus
    @State private var popped = false

    private var symbolName: String {
        switch status {
        case .queued: return "moon.zzz.fill"
        case .analyzing: return "waveform.and.magnifyingglass"
        case .converting: return "waveform"
        case .done: return "checkmark.seal.fill"
        case .skipped: return "arrow.uturn.forward.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var label: String {
        switch status {
        case .queued: return "待機中"
        case .analyzing: return "解析中"
        case .converting: return "変換中"
        case .done: return "完了"
        case .skipped(let reason): return "スキップ（\(reason)）"
        case .failed(let reason): return "失敗: \(reason)"
        }
    }

    private var color: Color {
        switch status {
        case .queued, .skipped: return .gray
        case .analyzing: return .blue
        case .converting: return .purple
        case .done: return .green
        // 赤は避けて、責めてる感を出さないオレンジ（仕様書 4.2.1）
        case .failed: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            icon
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.16)))
        .fixedSize()
        // 状態の種類ごとにビューを作り直して、完了時のポップアニメを確実に発火させる
        .id(label)
    }

    @ViewBuilder
    private var icon: some View {
        let image = Image(systemName: symbolName)
        switch status {
        case .analyzing:
            image.symbolEffect(.pulse)
        case .converting:
            image.symbolEffect(.variableColor.iterative)
        case .done:
            image
                .scaleEffect(popped ? 1 : 0.2)
                .onAppear {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.45)) {
                        popped = true
                    }
                }
        default:
            image
        }
    }
}

#Preview {
    ContentView()
}
