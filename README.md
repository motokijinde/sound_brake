# SoundBrake

mp4ファイルから音声を抽出し、複数ファイル間でラウドネス（音量感）をそろえて
`.m4a` として書き出す、macOS向けの軽量ユーティリティです。

これまでシェルスクリプトで行っていた「音声抽出＋ラウドネス正規化」の処理を、
SwiftUIのネイティブアプリからドラッグ&ドロップで扱えるようにしたものです。
内部処理は既存の `extract_and_normalize.sh` のロジックをそのまま踏襲し、
GUIからffmpegプロセスを呼び出す構成になっています。

詳細な仕様は [mp4_audio_tool_spec.md](mp4_audio_tool_spec.md) を参照してください。

## 動作要件

- macOS 14 以降
- [Homebrew](https://brew.sh/) でインストールしたffmpeg

```bash
brew install ffmpeg
```

ffmpegバイナリは `/opt/homebrew/bin/ffmpeg` → `/usr/local/bin/ffmpeg` → `PATH`
の順に探索します。見つからない場合はアプリ側でアラートを表示します。

## 使い方

1. mp4ファイルをウィンドウにドラッグ&ドロップ（複数選択・フォルダごとの
   ドロップにも対応）
2. 出力先フォルダを指定
3. 目標ラウドネスを選択（デフォルト -16 LUFS）
4. 「変換開始」を押すと、ファイルごとに解析→変換が進み、進捗が表示されます
5. 途中で気が変わったら「中止」でいつでも止められ、「再開」で待機中の
   ファイルだけ続きから処理できます

## プロジェクト構成

```
SoundBrake.xcodeproj/     Xcodeプロジェクト
SoundBrake/               アプリ本体のSwiftソース
  SoundBrakeApp.swift        エントリポイント
  ContentView.swift          メイン画面（UI）
  ConversionManager.swift    変換キューの管理・進捗更新
  FFmpegRunner.swift         ffmpegプロセスの起動・出力パース
  Models.swift               ジョブの状態を表すデータモデル
  Assets.xcassets/           アプリアイコン
AppIcons/                 アプリアイコンの元素材
mp4_audio_tool_spec.md    仕様書
extract_and_normalize.sh  元になったシェルスクリプト（内部ロジックの参照実装）
normalize_audio.sh        同上（正規化のみを行う版）
extract_audio.sh          同上（抽出のみを行う版）
```

## ビルド方法

### Xcodeで開く場合

`SoundBrake.xcodeproj` を開き、通常どおり実行（`⌘R`）またはアーカイブ
（Product → Archive）すればビルドできます。

### コマンドラインでビルドする場合

```bash
xcodebuild -project SoundBrake.xcodeproj -configuration Release build
```

> **補足**: このリポジトリをiCloud Drive配下（`Documents`など）に置いている場合、
> ビルド出力にiCloud同期用の拡張属性が付き、コード署名が失敗することがあります。
> その場合は `SYMROOT` / `OBJROOT` をiCloud圏外のパスに指定すると回避できます。
>
> ```bash
> xcodebuild -project SoundBrake.xcodeproj -configuration Release \
>   SYMROOT=/tmp/soundbrake_build OBJROOT=/tmp/soundbrake_obj build
> ```

## 技術構成

- Swift + SwiftUI（一部AppKitを併用: `NSOpenPanel` など）
- `Process` でffmpegバイナリを直接起動（`-nostdin` 相当の対策込み）
- 変換は2パス方式（1パス目で `loudnorm` によるラウドネス測定 → 2パス目で
  測定値を使った音声抽出＋正規化）
- v1では1ファイルずつ逐次処理

## v1スコープ外（今後の検討事項）

- 抽出のみ／正規化のみを選べるトグル
- 目標ラウドネスのプリセット切り替え（配信用/放送用など）
- ffmpegバイナリのアプリ内バンドル
- 変換後ファイルのプレビュー再生
- 複数フォルダのドロップ時の再帰探索
- アプリ再起動をまたいだ処理状態の永続化
