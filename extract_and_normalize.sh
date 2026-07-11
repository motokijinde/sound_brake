#!/bin/bash
# 使い方: ./extract_and_normalize.sh [対象フォルダ] [目標ラウドネスLUFS]
#   対象フォルダ省略時はカレントディレクトリ
#   目標ラウドネス省略時は -16（配信・ポッドキャスト向けの目安）
#     参考: -16 = 配信/ポッドキャスト、-23 = 放送基準(EBU R128)、-14 = Spotify等ストリーミング
#
# 例) ./extract_and_normalize.sh ~/Movies -18
#
# フォルダ以下（サブフォルダ含む）のmp4ファイルを再帰的に検索し、
# 音声抽出とラウドネス正規化（2パス方式）をまとめて実行する。
# 出力は "元ファイル名.m4a"（中間ファイルは作らない・既存ファイルは上書きしない）

TARGET_DIR="${1:-.}"
TARGET_I="${2:--16}"

if ! command -v ffmpeg &> /dev/null; then
  echo "エラー: ffmpegが見つからないよ〜。'brew install ffmpeg' で入れてね" >&2
  exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
  echo "エラー: フォルダが見つからないよ〜: $TARGET_DIR" >&2
  exit 1
fi

echo "目標ラウドネス: ${TARGET_I} LUFS"
echo "対象フォルダ: $TARGET_DIR"
echo "---"

find "$TARGET_DIR" -type f -iname "*.mp4" -print0 | while IFS= read -r -d '' file; do
  dir=$(dirname "$file")
  base=$(basename "$file" .mp4)
  output="$dir/${base}.m4a"

  if [ -f "$output" ]; then
    echo "スキップ（既に存在）: $output"
    continue
  fi

  echo "解析中: $file"

  # 1パス目: ラウドネス測定（JSON出力、映像は無視）
  measured=$(ffmpeg -nostdin -i "$file" -vn -af "loudnorm=I=${TARGET_I}:LRA=11:TP=-1.5:print_format=json" -f null - 2>&1)

  measured_I=$(echo "$measured" | grep '"input_i"' | sed -E 's/[^0-9.-]*(-?[0-9.]+).*/\1/')
  measured_LRA=$(echo "$measured" | grep '"input_lra"' | sed -E 's/[^0-9.-]*(-?[0-9.]+).*/\1/')
  measured_TP=$(echo "$measured" | grep '"input_tp"' | sed -E 's/[^0-9.-]*(-?[0-9.]+).*/\1/')
  measured_thresh=$(echo "$measured" | grep '"input_thresh"' | sed -E 's/[^0-9.-]*(-?[0-9.]+).*/\1/')
  offset=$(echo "$measured" | grep '"target_offset"' | sed -E 's/[^0-9.-]*(-?[0-9.]+).*/\1/')

  if [ -z "$measured_I" ]; then
    echo "  → 解析失敗（スキップ）: $file" >&2
    continue
  fi

  echo "変換中: $file → $output"

  # 2パス目: 測定値を使って音声抽出+正規化を同時に適用
  if ffmpeg -nostdin -y -i "$file" -vn -af "loudnorm=I=${TARGET_I}:LRA=11:TP=-1.5:measured_I=${measured_I}:measured_LRA=${measured_LRA}:measured_TP=${measured_TP}:measured_thresh=${measured_thresh}:offset=${offset}:linear=true:print_format=summary" -ar 48000 -c:a aac -b:a 192k "$output" -loglevel error; then
    echo "  → 完了: $output"
  else
    echo "  → 失敗: $file" >&2
  fi
done

echo "---"
echo "全部の処理が終わったよ〜！"
