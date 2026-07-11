import Foundation

/// ファイル1件の変換状態（仕様書 4.3 の状態遷移に対応）
enum ConversionStatus: Equatable {
    case queued
    case analyzing(progress: Double)
    case converting(progress: Double)
    case done
    case skipped(reason: String)
    case failed(reason: String)
    // 中止時は analyzing/converting → queued に差し戻すだけなので、
    // 専用の cancelled ケースは持たない（仕様書 3.5 参照）

    /// ffmpeg が現在処理中かどうか（この間は行削除を禁止する）
    var isActive: Bool {
        switch self {
        case .analyzing, .converting: return true
        default: return false
        }
    }

    /// 処理が終わっている（完了・スキップ・失敗）かどうか
    var isFinished: Bool {
        switch self {
        case .done, .skipped, .failed: return true
        default: return false
        }
    }

    /// ファイル全体の進捗（1パス目50% + 2パス目50% で合算）
    var progress: Double {
        switch self {
        case .queued: return 0
        case .analyzing(let p): return p * 0.5
        case .converting(let p): return 0.5 + p * 0.5
        case .done, .skipped: return 1
        case .failed: return 0
        }
    }
}

struct ConversionJob: Identifiable, Equatable {
    let id = UUID()
    let sourceURL: URL
    var status: ConversionStatus = .queued

    var fileName: String { sourceURL.lastPathComponent }

    /// 出力ファイル名は「元のファイル名（拡張子なし）+ .m4a」で統一
    var outputFileName: String {
        sourceURL.deletingPathExtension().lastPathComponent + ".m4a"
    }
}
