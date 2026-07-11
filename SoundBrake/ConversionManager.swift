import Foundation

/// 変換キュー全体を管理する ViewModel。
/// 処理は仕様書 5.3 のパイプラインどおり、1ファイルずつ逐次実行する。
@MainActor
final class ConversionManager: ObservableObject {
    /// 主対象は mp4。ffmpeg 側は他コンテナも扱えるので、ここに足すだけで拡張できる
    static let allowedExtensions: Set<String> = ["mp4"]

    @Published var jobs: [ConversionJob] = []
    @Published var outputDirectory: URL? {
        didSet {
            UserDefaults.standard.set(outputDirectory?.path, forKey: Self.outputDirectoryKey)
        }
    }
    @Published var targetLoudness: Int = -16
    @Published var isRunning = false
    @Published var errorMessage: String?

    private static let outputDirectoryKey = "outputDirectoryPath"
    private var worker: Task<Void, Never>?
    private var currentTask: FFmpegTask?
    private var stopRequested = false
    /// 実行中パスの入力総尺（stderr の Duration 行から取得。パスごとにリセット）
    private var currentDuration: Double?

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.outputDirectoryKey) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                outputDirectory = URL(fileURLWithPath: path)
            }
        }
    }

    // MARK: - リスト操作

    func addFiles(_ urls: [URL]) {
        var found: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                // フォルダごとドロップされた場合は中の対象ファイルを再帰的に拾う
                guard let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: nil) else { continue }
                for case let child as URL in enumerator
                where Self.allowedExtensions.contains(child.pathExtension.lowercased()) {
                    found.append(child)
                }
            } else if Self.allowedExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        let existing = Set(jobs.map { $0.sourceURL.standardizedFileURL })
        var seen = existing
        for url in found {
            let key = url.standardizedFileURL
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            jobs.append(ConversionJob(sourceURL: url))
        }
    }

    /// リストから削除（出力ファイルには一切触れない）。処理中の行は削除できない
    func removeJob(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              !jobs[index].status.isActive else { return }
        jobs.remove(at: index)
    }

    // MARK: - UI 用の集計

    var hasQueuedJobs: Bool {
        jobs.contains { $0.status == .queued }
    }

    var finishedCount: Int {
        jobs.filter { $0.status.isFinished }.count
    }

    var allFinished: Bool {
        !jobs.isEmpty && finishedCount == jobs.count
    }

    /// 中止後に待機中ジョブが残っていれば「再開」、それ以外は「変換開始」
    var startButtonLabel: String {
        (hasQueuedJobs && jobs.contains { $0.status.isFinished }) ? "再開" : "変換開始"
    }

    var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        let total = jobs.reduce(0.0) { sum, job in
            // 失敗も「処理済み」として全体バーには 1 で計上する
            if case .failed = job.status { return sum + 1 }
            return sum + job.status.progress
        }
        return total / Double(jobs.count)
    }

    // MARK: - 実行制御

    func start() {
        guard !isRunning else { return }
        guard outputDirectory != nil else {
            errorMessage = "出力先フォルダを選択してください。"
            return
        }
        guard FFmpegLocator.find() != nil else {
            errorMessage = "ffmpegが見つかりません。ターミナルで brew install ffmpeg を実行してください。"
            return
        }
        stopRequested = false
        isRunning = true
        worker = Task { await self.processQueue() }
    }

    /// 実行中の ffmpeg を止め、以降のキュー処理も止める。
    /// 処理中だったジョブは「待機中」に差し戻す（processJob 側で実施）
    func cancel() {
        guard isRunning else { return }
        stopRequested = true
        currentTask?.terminate()
    }

    // MARK: - パイプライン

    private func processQueue() async {
        guard let ffmpeg = FFmpegLocator.find(), let outputDir = outputDirectory else {
            isRunning = false
            return
        }
        while !stopRequested {
            guard let jobID = jobs.first(where: { $0.status == .queued })?.id else { break }
            await processJob(jobID, ffmpeg: ffmpeg, outputDir: outputDir)
        }
        isRunning = false
    }

    private func processJob(_ jobID: UUID, ffmpeg: URL, outputDir: URL) async {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        let inputPath = job.sourceURL.path
        let outputURL = outputDir.appendingPathComponent(job.outputFileName)

        // 1. 出力先に同名ファイルが存在すればスキップ（中止→再開時の安全装置も兼ねる）
        if FileManager.default.fileExists(atPath: outputURL.path) {
            updateJob(jobID) { $0.status = .skipped(reason: "既存") }
            return
        }

        let loudnormBase = "loudnorm=I=\(targetLoudness):LRA=11:TP=-1.5"

        // 2. 1パス目: ラウドネス測定（JSON出力、映像は無視）
        updateJob(jobID) { $0.status = .analyzing(progress: 0) }
        currentDuration = nil
        guard let pass1 = await runPass(
            ffmpeg: ffmpeg,
            arguments: [
                "-nostdin", "-i", inputPath, "-vn",
                "-af", loudnormBase + ":print_format=json",
                "-f", "null", "-",
            ],
            jobID: jobID, phase: .analyzing
        ) else {
            updateJob(jobID) { $0.status = .failed(reason: "起動失敗") }
            return
        }

        if stopRequested {
            updateJob(jobID) { $0.status = .queued }
            return
        }

        // 3. JSON取得失敗 → 解析失敗として次のファイルへ
        guard pass1.exitCode == 0,
              let measured = LoudnormMeasurement(fromStderr: pass1.stderr) else {
            updateJob(jobID) { $0.status = .failed(reason: "解析失敗") }
            return
        }

        // 4. 2パス目: 測定値を使って音声抽出+正規化を同時に適用
        updateJob(jobID) { $0.status = .converting(progress: 0) }
        currentDuration = nil
        let filter = loudnormBase
            + ":measured_I=\(measured.inputI)"
            + ":measured_LRA=\(measured.inputLRA)"
            + ":measured_TP=\(measured.inputTP)"
            + ":measured_thresh=\(measured.inputThresh)"
            + ":offset=\(measured.targetOffset)"
            + ":linear=true:print_format=summary"
        let pass2 = await runPass(
            ffmpeg: ffmpeg,
            arguments: [
                "-nostdin", "-y", "-i", inputPath, "-vn",
                "-af", filter,
                "-ar", "48000", "-c:a", "aac", "-b:a", "192k",
                outputURL.path,
            ],
            jobID: jobID, phase: .converting
        )

        if stopRequested {
            // 中止時、未完成の出力ファイルは削除して「待機中」に差し戻す
            try? FileManager.default.removeItem(at: outputURL)
            updateJob(jobID) { $0.status = .queued }
            return
        }

        // 5. 成功 → 完了、失敗 → 中途半端な出力を消して失敗として記録
        if let pass2, pass2.exitCode == 0 {
            updateJob(jobID) { $0.status = .done }
        } else {
            try? FileManager.default.removeItem(at: outputURL)
            updateJob(jobID) { $0.status = .failed(reason: "変換失敗") }
        }
    }

    private enum Phase {
        case analyzing
        case converting
    }

    private func runPass(
        ffmpeg: URL, arguments: [String], jobID: UUID, phase: Phase
    ) async -> (exitCode: Int32, stderr: String)? {
        let task = FFmpegTask()
        currentTask = task
        defer { currentTask = nil }
        do {
            return try await task.run(executable: ffmpeg, arguments: arguments) { [weak self] line in
                Task { @MainActor in
                    self?.handleProgressLine(line, jobID: jobID, phase: phase)
                }
            }
        } catch {
            return nil
        }
    }

    /// stderr の "Duration:" で総尺を拾い、"time=" と比較して進捗を更新する
    private func handleProgressLine(_ line: String, jobID: UUID, phase: Phase) {
        if let duration = parseTimestamp(after: "Duration: ", in: line) {
            currentDuration = duration
        }
        guard let duration = currentDuration, duration > 0,
              let time = parseTimestamp(after: "time=", in: line) else { return }
        let progress = min(max(time / duration, 0), 1)
        updateJob(jobID) {
            switch phase {
            case .analyzing: $0.status = .analyzing(progress: progress)
            case .converting: $0.status = .converting(progress: progress)
            }
        }
    }

    private func updateJob(_ id: UUID, _ transform: (inout ConversionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        transform(&jobs[index])
    }
}
