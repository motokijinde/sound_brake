#!/bin/bash
# 使い方: ./normalize_audio.sh 対象フォルダ 出力先フォルダ [目標ラウドネスLUFS]
#   目標ラウドネス省略時は -16（配信・ポッドキャスト向けの目安）
#     参考: -16 = 配信/ポッドキャスト、-23 = 放送基準(EBU R128)、-14 = Spotify等ストリーミング
#
# 例) ./normalize_audio.sh ~/Music/元音源 ~/Music/正規化済み -18
#
# 対象フォルダ以下（サブフォルダ含む）のm4aファイルを再帰的に検索し、
# 2パスのラウドネス正規化（loudnorm）で音量をそろえて、出力先フォルダへ
# 「元ファイルと同じファイル名」で書き出す（フォルダ構成もそのままミラーリング）。
# 元ファイルには一切手を加えない。
#
# 特殊文字・文字コードの問題でffmpegが直接ファイルを開けないケースに対応するため、
# 処理前に一時的にASCIIだけの安全な名前へハードリンク（不可ならコピー）してから読み込む。

SOURCE_DIR="${1:?対象フォルダを指定してね}"
OUTPUT_DIR="${2:?出力先フォルダを指定してね（例: ./normalize_audio.sh ソース先 出力先）}"
TARGET_I="${3:--16}"

SOURCE_DIR="${SOURCE_DIR%/}"
TMP_DIR="$SOURCE_DIR/.normalize_tmp"

if ! command -v ffmpeg &> /dev/null; then
  echo "エラー: ffmpegが見つからないよ〜。'brew install ffmpeg' で入れてね" >&2
  exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
  echo "エラー: 対象フォルダが見つからないよ〜: $SOURCE_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
mkdir -p "$TMP_DIR"

echo "目標ラウドネス: ${TARGET_I} LUFS"
echo "対象フォルダ: $SOURCE_DIR"
echo "出力先フォルダ: $OUTPUT_DIR"
echo "---"

i=0
find "$SOURCE_DIR" -type f -iname "*.m4a" -print0 | while IFS= read -r -d '' file; do
  # 出力先フォルダが対象フォルダの中にある場合、そこに書き出した分を再度拾わないようにする
  case "$file" in
    "$OUTPUT_DIR"/*) continue ;;
  esac

  i=$((i+1))

  rel_path="${file#$SOURCE_DIR/}"
  output="$OUTPUT_DIR/$rel_path"
  output_dir=$(dirname "$output")
  mkdir -p "$output_dir"

  if [ -f "$output" ]; then
    echo "スキップ（既に存在）: $output"
    continue
  fi

  tmp_in="$TMP_DIR/tmp_${i}.m4a"
  rm -f "$tmp_in"
  if ! ln "$file" "$tmp_in" 2>/dev/null; then
    # ハードリンクできない場合（別ボリュームなど）はコピーにフォールバック
    cp "$file" "$tmp_in"
  fi

  echo "解析中: $file"

  # 1パス目: ラウドネス測定（安全な一時ファイル名で読み込む）
  measured=$(ffmpeg -nostdin -i "$tmp_in" -af "loudnorm=I=${TARGET_I}:LRA=11:TP=-1.5:print_format=json" -f null - 2>&1)

  measured_I=$(echo "$measured" | grep '"input_i"' | sed -E 's/[^0-9.-]*(-?[0-9.]+).*/\1/')
  measured_LRA=$(echo "$measured" | grep '"input_lra"' | sed -E 's/[^0-9.-]*(-?[0-9.]+).*/\1/')
  measured_TP=$(echo "$measured" | grep '"input_tp"' | sed -E 's/[^0-9.-]*(-?[0-9.]+).*/\1/')
  measured_thresh=$(echo "$measured" | grep '"input_thresh"' | sed -E 's/[^0-9.-]*(-?[0-9.]+).*/\1/')
  offset=$(echo "$measured" | grep '"target_offset"' | sed -E 's/[^0-9.-]*(-?[0-9.]+).*/\1/')

  if [ -z "$measured_I" ]; then
    echo "  → 解析失敗（スキップ）: $file" >&2
    echo "  ---- ffmpeg診断ログ（末尾20行）----" >&2
    echo "$measured" | tail -n 20 >&2
    echo "  --------------------------------" >&2
    rm -f "$tmp_in"
    continue
  fi

  echo "変換中: $file → $output"

  # 2パス目: 測定値を使って正規化を適用
  if ffmpeg -nostdin -y -i "$tmp_in" -af "loudnorm=I=${TARGET_I}:LRA=11:TP=-1.5:measured_I=${measured_I}:measured_LRA=${measured_LRA}:measured_TP=${measured_TP}:measured_thresh=${measured_thresh}:offset=${offset}:linear=true:print_format=summary" -ar 48000 -c:a aac -b:a 192k "$output" -loglevel error; then
    echo "  → 完了: $output"
  else
    echo "  → 失敗: $file" >&2
  fi

  rm -f "$tmp_in"
done

rmdir "$TMP_DIR" 2>/dev/null

echo "---"
echo "全部の処理が終わったよ〜！"
