# ccglance

Claude Code の稼働状況を、menu bar ではなく**常に最前面のフローティングパネル**で表示する macOS アプリ。サブモニターの隅に置いておけば、どのセッションが動作中・許可待ち・完了かを一目で確認できます。

[claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) と同じ hooks 方式で動作しますが、複数セッションを同時に一覧表示します。

## 表示内容

各行に 1 セッション（プロジェクト）:

- **アニメーションスパーク**（オレンジ #d97757） — Thinking / ツール実行中
- **プロジェクト名** — セッションの作業ディレクトリ名
- **状態ラベル** — `Thinking…` / `Editing` / `Reading` / `Running command` / `Awaiting permission` / `Idle`
- **経過時間** — 現在のターンの経過タイマー（`1m 23s`）
- **許可待ち** — 黄色いドット + 行が黄色くパルスして強調

## ウィンドウの挙動

- 常に最前面（フルスクリーンアプリの上にも表示）
- 全 Spaces / 全モニターで表示 — サブモニターに置きっぱなしにできる
- ドラッグでどこへでも移動可・位置は記憶される
- 半透明 HUD デザイン、フォーカスを奪わない（クリックしても作業中のアプリからフォーカスが外れない）
- Dock アイコンなし
- 右クリックメニュー: 終了 / 完了セッションのクリア / hooks 再インストール / アップデート確認

## 必要環境

- macOS 12+
- Xcode Command Line Tools（ビルド用）: `xcode-select --install`
- Node.js（hooks スクリプト用）
- Claude Code（CLI または Desktop アプリ）

## ビルドとインストール

```bash
./build.sh
cp -R build/ccglance.app /Applications/
open /Applications/ccglance.app
```

初回起動時に Claude Code の hooks を自動設定します（`~/.claude/settings.json` に追記。既存の hooks には触れず、`settings.json.bak-ccglance` にバックアップを作成）。

> **すでに Claude Code を開いている場合は再起動（または新しいセッションを開始）してください。** hooks はセッション開始時に読み込まれます。

自動セットアップが動かない場合は手動で:

```bash
node "/Applications/ccglance.app/Contents/Resources/install.js"
```

## 仕組み

Claude Code のライフサイクル hooks（SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Notification / Stop / SessionEnd）が、セッションごとの状態を `~/.claude/ccglance/sessions/<session_id>.json` に書き込みます。アプリはこのディレクトリを 0.25 秒間隔でポーリングして描画します。

- セッション終了時に状態ファイルは削除されます
- 12 時間更新のないファイル（クラッシュしたセッション）は自動削除されます
- `SessionStart` 時にアプリを自動起動します（`open -g -a ccglance`）

### 対応範囲

| Surface | 対応 |
| --- | --- |
| Claude Code CLI | ✅ |
| Claude Code Desktop（Code タブ） | ✅ |
| Claude Desktop（Chat）/ Cowork | ❌（hooks 非対応） |

許可待ち検出は CLI の permission notification に依存します。Desktop アプリでは in-app プロンプトが hook を発火しないため、ツール名表示のままになります。

## アップデート

GitHub Releases の最新版を起動 5 秒後と 24 時間ごとにチェックします（前回チェックから 24 時間未満なら起動時チェックはスキップ）。新しいバージョンが見つかると:

- パネル下部にオレンジのバナー「⬆ Update to vX.Y.Z」が表示されます
- 右クリックメニューに「Update to ccglance vX.Y.Z…」が追加されます

クリックすると **その場でアップデート** します: リリースの zip をダウンロード → 展開 → 実行中の `.app` を置き換え → 自動で再起動。ダウンロードや置き換えに失敗した場合はロールバックし、リリースページをブラウザで開きます（zip アセットが無いリリースも同様）。

手動チェックは右クリックメニューの「Check for updates…」から。

リリース手順（メンテナ向け）:

1. `build.sh` の `VERSION` を上げる（Info.plist に反映されます）
2. `./build.sh` でビルド（`build/ccglance-v<VERSION>.zip` と `.zip.sha256` も生成されます）
3. `v<VERSION>` タグで GitHub Release を作成し、zip と `.sha256` を**両方**添付（無いと自動更新できず、リリースページ誘導になります）

チェック先リポジトリは `Sources/UpdateChecker.swift` の `UpdateChecker.repo` で変更できます。

## アンインストール

```bash
node "/Applications/ccglance.app/Contents/Resources/uninstall.js"
```

その後アプリをゴミ箱へ。ccglance の hooks のみが削除され、他の hooks はそのまま残ります。

## ライセンス

MIT
