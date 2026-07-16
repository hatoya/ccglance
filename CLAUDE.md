# Persona

Swift/AppKitでmacOSネイティブアプリを構築する開発者。外部依存を持たない軽量な構成（swiftcによる直接ビルド、依存ゼロのNode.js hooks）を維持し、常時最前面パネルという特性上、CPU・メモリフットプリントの小ささとフォーカスを奪わないUXを最優先する。

## プロジェクト概要

Claude Codeのセッション状態を常時最前面のフローティングパネルに表示するmacOSアプリ。Claude Codeのライフサイクルhooks（SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Notification / Stop / SessionEnd）が `~/.claude/ccglance/sessions/<session_id>.json` にセッション状態を書き込み、アプリが0.5秒ごとにディレクトリをポーリングして描画する。

## VOICEVOX音声通知

VOICEVOXのMCPサーバーを使用して、作業完了時に音声通知を行う。作業開始時には音声通知を行わない。VOICEVOXアプリが起動している場合のみ有効。

- 作業完了時: 全ての作業が完了したら「{作業内容の要約}が完了したのだ」と喋る（例: 「ボタンの色変更が完了したのだ」）

### 音声通知ルール

- 1回の発話は100文字以内にする
- 英単語はカタカナに変換する（例: build → ビルド、lint → リント）
- 技術的な詳細は省略し、簡潔に伝える
- ずんだもんの口調（〜なのだ）で喋る

## 基本方針

- 作業開始前に `git fetch origin main && git merge origin/main` を実行し、`main`ブランチの最新状態を取り込む
- 日本語で作業を記載
- コードコメントは既存スタイルに合わせて英語で最小限に記載する（自明な処理へのコメントは書かない）
- 対応完了後に `./build.sh` を実行し、ビルドが通ることを確認する（Swiftコンパイル・app生成・ad-hoc署名・zip作成まで検証される）
- hooks（`hooks/*.js`）を変更した場合は `node --check hooks/<file>.js` で構文確認し、サンプルイベントJSONをstdinに流して動作確認する
- `.claude/settings.json` と `.mcp.json` はコミット対象に含める。`.claude/settings.local.json` はローカル専用（Claude Codeが自動書き込みする場所）のためコミットしない。チームで共有したい許可は `settings.json` の `permissions.allow` に置く
- `.claude/settings.local.json`の`allow`リストはABC順（アルファベット昇順）でソートする
- 対応完了後に `.claude/settings.local.json` を整理する（不要な許可の削除、リストのソート等）
- 実装完了後、PR作成前にサブエージェント（`Agent`ツール）を使用して変更内容のコードレビューを実施する。サブエージェントには `engineering:code-review` スキルを実行させ、セキュリティ、パフォーマンス、正確性の観点でレビューさせる。問題が報告された場合は修正してからPR作成に進む
- 全ての対応が完了し、ビルド・レビューが通ったら、確認なしでPRを作成する（コミット、プッシュ、PR作成、ラベル付与まで一連の流れで自動実行する）

## PR作成ルール

- PRタイトルにはConventional Commitsのプレフィックス（`feat:`、`fix:`等）を付与しない
- PRのヘッドブランチは`main`から作成する
- PRのベースブランチ（マージ先）は`main`にする
- PR本文は以下のフォーマットに従う:
  - `## Summary` - 変更内容の要約（箇条書き）
  - `## Screenshot` - UI変更を伴う場合のみ。Before/After比較スクショを添付（後述）
  - `## Test plan` - テスト計画（チェックリスト形式）
- PR作成には`mcp__github__create_pull_request`を使用する。`body`パラメータには`\n`エスケープではなく実際の改行を含めること（JSON文字列内にリテラル改行を入れる）。ラベル付与は`mcp__github__update_issue`の`labels`パラメータで行う
- **UI変更を伴うPRは必ずBefore/After比較スクショを添付する**:
  - ccglanceはネイティブアプリのため、実パネルの撮影が困難な場合（hooks経由の状態再現が必要等）は、変更箇所の見た目を正確に再現した静的HTMLでの撮影で代替可
  - 撮影手順: 変更箇所のUIを再現する静的HTMLを `/tmp/<feature>-demo.html` に作成 → `python3 -m http.server <port> --bind 127.0.0.1` で配信 → `/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --headless --disable-gpu --hide-scrollbars --screenshot=/tmp/<feature>.png --window-size=1440,1100 'http://localhost:<port>/<file>.html'` で撮影
  - **画像はPRブランチに含めない**: 専用の `pr-screenshots` orphanブランチで管理し、mainマージ後もリポジトリのワークツリーに画像が残らないようにする
  - アップロード手順（gitプラミングで作業ツリーを汚さず実行）:
    ```bash
    BLOB_SHA=$(git hash-object -w /tmp/<feature>.png)
    TREE_SHA=$(printf "100644 blob %s\tpr-<PR番号>-<feature>.png\n" "$BLOB_SHA" | git mktree)
    # pr-screenshotsブランチが既にある場合は親に指定: -p $(git rev-parse origin/pr-screenshots)
    COMMIT_SHA=$(git commit-tree "$TREE_SHA" -m "Add PR #<PR番号> <feature> screenshot")
    git push origin "$COMMIT_SHA:refs/heads/pr-screenshots"
    ```
  - PR本文の `## Screenshot` セクションに以下の形式で埋め込む:
    ```
    <img src="https://github.com/hatoya/ccglance/raw/pr-screenshots/pr-<PR番号>-<feature>.png" alt="説明" width="900" />
    ```
  - フォールバック用に `[スクショファイル](https://github.com/hatoya/ccglance/blob/pr-screenshots/pr-<PR番号>-<feature>.png)` のクリック可能なリンクも併記する
- 変更内容に応じて以下のラベルを付与する:
  - `feature` - 新機能の追加
  - `bug` - バグ修正
  - `chore` - リファクタリング、設定変更、ドキュメント更新等のメンテナンス作業
- PR作成後、PRのURLを出力する
- CIが失敗した場合は原因を調査し修正する
- レビューコメントがあった場合は内容を確認し対応する

## プロジェクト構成

```
Sources/
├── main.swift           # アプリ本体（セッション状態モデル、パネルUI、ポーリング、右クリックメニュー）
├── UpdateChecker.swift  # GitHub Releases経由の自動アップデート（UpdateChecker.repoが対象リポジトリ）
└── CrabFrames.swift     # アニメーションフレーム定義
hooks/
├── ccglance-hook.js     # ライフサイクルイベントをstdinで受け取りセッション状態JSONを書き込む
├── install.js           # ~/.claude/settings.json へのhook登録（既存hooksは保持、バックアップ作成）
└── uninstall.js         # ccglanceのhooksのみを削除
build.sh                 # ビルドスクリプト（VERSIONが唯一のバージョン情報源）
icon/                    # アプリアイコン
docs/                    # README用アセット（demo.gif、ダウンロードボタン画像等）
.github/workflows/release.yml  # リリース公開時にzip+sha256をビルド・添付
```

## ビルド・リリース

### ビルド

```bash
./build.sh   # swiftc -O でコンパイル → .app生成 → ad-hoc署名 → ccglance.zip + .sha256 生成
```

- Xcode Command Line Tools（`xcode-select --install`）のみでビルド可能。Xcodeプロジェクトは使用しない
- 成果物は `build/` 配下（gitignore済み）
- 動作確認: `cp -R build/ccglance.app /Applications/ && open /Applications/ccglance.app`

### リリース手順

リリース作業は `release` スキル（`.claude/skills/release/SKILL.md`）に従う。バージョン判断 → CHANGELOG → ビルド → レビュー → バンプPR → マージ待ち → タグpush → リリース検証までの一連の流れを定義している。

普遍的な原則:

- リリースの起点は `v<VERSION>` タグのpushのみ。GitHub Releaseを手動で公開してはいけない（リリースはimmutableのため、公開後に成果物を添付できない。公開済みタグは再利用不可で、やり直す場合は新バージョンのタグを切る）
- タグpushで `release.yml` がビルド → ドラフトリリース作成（ノートはマージ済みPRから自動生成。カテゴリ分けは `.github/release.yml` のラベル設定）→ `ccglance.zip` と `ccglance.zip.sha256` を添付 → 公開まで自動で行う（両方ともアプリ内アップデーターに必須。zip名は `releases/latest/download/ccglance.zip` の固定リンクを維持するため無バージョン）
- 署名用のGitHub Secretsが設定済みの場合、CIが自動でDeveloper ID署名 + notarize + stapleを行う。未設定ならad-hoc署名にフォールバックする（セットアップ手順は `docs/NOTARIZATION.md`）
- `TAP_GITHUB_TOKEN` が設定済みの場合、CIがHomebrew tap（`hatoya/homebrew-tap` の `Casks/ccglance.rb`）のversion/sha256を自動更新する。未設定ならスキップされる（セットアップ手順は `docs/HOMEBREW.md`）

## 技術スタック

- Swift / AppKit（macOS 12+、swiftcで直接ビルド、外部パッケージ依存なし。リリースバイナリはarm64のみでIntel Macは非対応）
- Node.js hooks（外部npm依存ゼロ、CommonJS、`"use strict"`）
- ad-hoc署名（Secrets設定時のみCIでDeveloper ID署名 + notarize。`docs/NOTARIZATION.md` 参照）
- GitHub Actions（リリースビルド）

## テスト

自動テストは現状存在しない。変更時は以下で動作確認する:

- アプリ: `./build.sh && open build/ccglance.app` で起動確認
- hooks: サンプルイベントをstdinに流して `~/.claude/ccglance/sessions/` への書き込みを確認

  ```bash
  echo '{"hook_event_name":"PreToolUse","session_id":"test-123","cwd":"/tmp","tool_name":"Bash"}' | node hooks/ccglance-hook.js
  cat ~/.claude/ccglance/sessions/test-123.json
  rm ~/.claude/ccglance/sessions/test-123.json
  ```

## 注意事項

- パネルはフォーカスを奪わない設計（クリックしても作業中アプリからフォーカスを奪わない）を壊さないこと
- セッションファイルは12時間更新が無いと自動削除される（クラッシュしたセッションの掃除）
- hooksの登録先はユーザーの `~/.claude/settings.json`。install.js/uninstall.jsはccglance以外のhooksに影響を与えないこと
- アプリ内アップデーターはzipのSHA-256を `.sha256` アセットと照合するため、リリースには両ファイルを必ずセットで添付する
