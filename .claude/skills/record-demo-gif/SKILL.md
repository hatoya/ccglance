---
name: record-demo-gif
description: READMEデモGIF（docs/demo.gif）の撮影・再生成。パネルのUI変更後に「デモGIFを撮り直して」「demo.gifを更新して」と言われたら使う。借景ウィンドウ・デモセッション注入・ScreenCaptureKit連写・自前GIFエンコードまで一式を自動化する。
---

# READMEデモGIFの録画

`docs/demo.gif`（1046x752px・240フレーム・24秒ループ・約1MB）を実機で撮り直す手順。
ツール一式は `scripts/` に同梱済み。**手順の順番と検証を省略しないこと**（過去の失敗はすべて省略が原因）。

## 前提

- 実行プロセスに画面収録権限があること（`scripts/record.sh` 内のcaptureが失敗したらシステム設定→プライバシー→画面収録）
- デモ内容の定義は `docs/demo-sessions.js`（3セッション+2サブエージェント、24秒で状態が一巡）

## 手順

### 1. 録画専用フィルタを一時適用してビルド

他セッションのhook書き込みが映り込むのを防ぐ。`Sources/main.swift` の `StateStore.load()` 内、
`for url in files {` の直後に1行挿入:

```swift
guard url.lastPathComponent.hasPrefix("demo-readme") else { continue }  // RECORDING ONLY
```

その後 `bash build.sh`。**この行は録画後に必ずrevertする（コミット厳禁）**。

### 2. 録画

```bash
WORK=$(mktemp -d)
bash .claude/skills/record-demo-gif/scripts/record.sh "$(pwd)" "$WORK"
```

record.shがやること: ツールのコンパイル → aerial静止画抽出 → 稼働中ccglance停止 →
パネル幅を435ptに固定（元値は退避・終了時復元）→ 録画ビルド起動 → **ウォッチドッグ**
（録画PID以外のccglanceを0.3秒ごとにkill。並行セッションが無フィルタ版を起動して
パネルに被った事故の再発防止）→ デモセッション注入 → パネル成長待ち →
借景ウィンドウ（**キャプチャ領域=パネル+44ptぴったりのサイズ**。全画面に敷くと構図が変わる）→
24秒ループ境界まで待機 → 240フレーム@10fps連写 → 後片付け・/Applications版再起動。

### 3. 混入チェック（必須）

```bash
python3 .claude/skills/record-demo-gif/scripts/check_stability.py "$WORK/frames"
```

`unstable frames: none` 以外が出たら混入・レイアウト変動あり。フレームを目視して原因を潰し、撮り直す。

### 4. エンコードと検証

```bash
"$WORK/bin/gifenc" "$WORK/frames" "$WORK/demo.gif" 10
"$WORK/bin/verify" "$WORK/demo.gif" "$WORK"
```

- verifyの出力が「240フレーム・24.0秒・全フレーム同寸」であること
- `$WORK/decoded*.png` をReadで目視（枠線・影・行内容・ちらつき/ゴーストなし）
- Chromium実再生: `$WORK` でHTTPサーバを立ててブラウザで開き、数秒おきに2回スクショを
  撮ってタイマー進行とアニメーションを確認

### 5. 反映と後片付け

1. 手順1のフィルタ行をrevert → `bash build.sh`（クリーンビルドに戻す）
2. `git diff Sources/main.swift` が空（またはRECORDING ONLY行を含まない）ことを確認。
   **フィルタ行をコミットしたら実ユーザーのパネルに何も表示されなくなる**
3. `cp "$WORK/demo.gif" docs/demo.gif`
4. `rm -rf "$WORK"`

## 実装ノート（変更する前に読む）

- GIFエンコードにImageIOを使ってはいけない（フレーム毎パレット再量子化でちらつく）。
  gifenc.swiftは グローバルmedian-cut 255色 + Bayer 8x8順序ディザ strength 8（位置決定的）
  + 時間デノイズ（最後に出力したソース値と全ch差6以下は未変更扱い。キャプチャに乗る
  コンポジタ由来±1-2 LSBノイズで差分が肥大するのを防ぐ）+ フレーム間差分
  （disposal=1・インデックス255透過・変化bboxのみ）+ 自前LZW
- FS誤差拡散・CIDitherランダムノイズは過去にユーザーから却下済み。ディザ方式を変えない
- 縮小出力しない。Retinaネイティブ2xのままGIF化し、READMEの `<img width="523">` で論理サイズ表示
- パネルの実行時levelは3。bgwinはlevel-1（capture/bgwinとも実行時に動的検出する）
- record.shのタイミング（sleep類）は node起動→24秒境界合わせに効いているので不用意に変えない
