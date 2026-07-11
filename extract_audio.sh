#!/bin/bash
# 使い方: ./extract_audio.sh [対象フォルダ]（省略時はカレントディレクトリ）
# 指定フォルダ以下（サブフォルダ含む）のmp4ファイルを再帰的に検索し、
# 音声だけをm4a（再エンコードなし）として抜き出す
#
# 例) video.mp4 → video.m4a

TARGET_DIR="${1:-.}"

if ! command -v ffmpeg &> /dev/null; then
  echo "エラー: ffmpegが見つからないよ〜。'brew install ffmpeg' で入れてね" >&2
  exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
  echo "エラー: フォルダが見つからないよ〜: $TARGET_DIR" >&2
  exit 1
fi

count_ok=0
count_skip=0
count_fail=0

find "$TARGET_DIR" -type f -iname "*.mp4" -print0 | while IFS= read -r -d '' file; do
  dir=$(dirname "$file")
  base=$(basename "$file" .mp4)
  output="$dir/$base.m4a"

  if [ -f "$output" ]; then
    echo "スキップ（既に存在）: $output"
    continue
  fi

  echo "変換中: $file"
  if ffmpeg -nostdin -y -i "$file" -vn -acodec copy "$output" -loglevel error; then
    echo "  → 完了: $output"
  else
    echo "  → 失敗: $file" >&2
  fi
done

echo "全部の処理が終わったよ〜！"
