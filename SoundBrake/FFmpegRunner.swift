import Foundation

/// ffmpeg バイナリの探索（/opt/homebrew → /usr/local → PATH の順）
enum FFmpegLocator {
    private static let searchPaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
    ]

    static func find() -> URL? {
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // PATH 経由のフォールバック
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "ffmpeg"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// loudnorm 1パス目の JSON 出力から取り出した測定値
struct LoudnormMeasurement {
    let inputI: String
    let inputLRA: String
    let inputTP: String
    let inputThresh: String
    let targetOffset: String

    /// 1パス目の stderr 全文から測定値を抽出（シェルスクリプトの grep/sed 相当）
    init?(fromStderr stderr: String) {
        func value(forKey key: String) -> String? {
            capture(#""\#(key)"\s*:\s*"(-?[0-9.]+)""#, in: stderr)
        }
        guard let i = value(forKey: "input_i"),
              let lra = value(forKey: "input_lra"),
              let tp = value(forKey: "input_tp"),
              let thresh = value(forKey: "input_thresh"),
              let offset = value(forKey: "target_offset") else { return nil }
        inputI = i
        inputLRA = lra
        inputTP = tp
        inputThresh = thresh
        targetOffset = offset
    }
}

/// 正規表現の最初のキャプチャグループを取り出す小さなヘルパー
func capture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let fullRange = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: fullRange),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

/// "Duration: 00:03:12.34" や "time=00:03:12.34" の HH:MM:SS.ss を秒に変換
func parseTimestamp(after prefix: String, in line: String) -> Double? {
    guard let text = capture(prefix + #"(\d+:\d+:\d+(?:\.\d+)?)"#, in: line) else { return nil }
    let parts = text.split(separator: ":")
    guard parts.count == 3,
          let h = Double(parts[0]),
          let m = Double(parts[1]),
          let s = Double(parts[2]) else { return nil }
    return h * 3600 + m * 60 + s
}

/// ffmpeg 1回分の実行を包むラッパー。stderr を行単位でコールバックしつつ全文も保持する
final class FFmpegTask {
    private let process = Process()

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    /// ffmpeg を起動して終了まで待つ。stderr の各行（\r 区切りの進捗行を含む）を onLine に流す
    func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping (String) -> Void
    ) async throws -> (exitCode: Int32, stderr: String) {
        process.executableURL = executable
        process.arguments = arguments
        // 念のための stdin 対策（仕様書 5.2: -nostdin 相当の保険）
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe

        try process.run()

        let proc = process
        return await Task.detached(priority: .userInitiated) {
            let handle = pipe.fileHandleForReading
            var output = ""
            var buffer = ""
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                output += chunk
                buffer += chunk
                // ffmpeg の進捗行は \r 終端なので \r と \n の両方で分割する
                let pieces = buffer.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                buffer = pieces.last ?? ""
                for line in pieces.dropLast() where !line.isEmpty {
                    onLine(line)
                }
            }
            if !buffer.isEmpty {
                onLine(buffer)
            }
            proc.waitUntilExit()
            return (proc.terminationStatus, output)
        }.value
    }
}
