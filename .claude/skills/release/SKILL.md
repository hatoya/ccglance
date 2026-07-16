---
name: release
description: ccglanceの新バージョンをリリースする一連の流れを実行する。「リリース」「リリースして」「新バージョンを出して」と言われたら使う。バージョン判断→CHANGELOG→ビルド→レビュー→バンプPR→マージ待ち→タグpush→リリース検証まで一式を自動化する（PRマージのみユーザー操作）。
---

# リリース手順

リリースの起点は `v<VERSION>` タグのpushのみ。タグpushで `.github/workflows/release.yml` が
macOSランナーでビルド → ドラフトリリース作成（ノートはマージ済みPRから自動生成）→
`ccglance.zip` + `ccglance.zip.sha256` 添付 → 公開 → Homebrew tap更新まで自動で行う。

**GitHub Releaseを手動で公開してはいけない**。リリースはimmutableのため、公開後に成果物を
添付できず、アセット無しの壊れたリリースになる（v1.5.0〜v1.5.3で実際に起きた事故）。
公開済みタグは再利用不可。やり直す場合は新バージョンのタグを切る。

## 手順

### 1. 差分の確認とバージョン判断

```bash
git fetch origin main --tags                        # --tags必須（mainのfetchだけではタグが揃わないことがある）
git tag --sort=-v:refname | head -1                 # 前回リリースタグ
git log v<前回>..origin/main --oneline --merges      # 取り込まれたPR
gh pr list --repo hatoya/ccglance --state merged --limit 30 \
  --json number,title,labels --jq '.[] | "\(.number)\t\(.title)\t\([.labels[].name] | join(","))"'
```

`gh pr list` の結果は `git log --merges` のPR一覧と突合し、対象PRが揃っていることを確認する
（`gh pr list` は作成日降順のため、古いPRが後からマージされたケースを取りこぼしうる）。

PRラベルからバンプ幅を決める: `feature` が1つでもあればminor、`bug`/`chore` のみならpatch。
破壊的変更（設定・セッションJSONフォーマットの非互換等）があればmajor。

前回タグ以降のPRが無い場合はリリース不要と報告して終了する。

### 2. バージョンバンプとCHANGELOG

新しいブランチを `origin/main` から作成し（ヘッド・ベースとも`main`基準）、以下を変更:

- `build.sh` の `VERSION` を新バージョンに更新
- `CHANGELOG.md` の先頭に `## v<VERSION>` エントリを追加。既存エントリと同じ英語・箇条書きで、
  **前リリース以降の変更のみ**を記載する。手順1のPR一覧と突合し、漏れ・過剰記載がないこと

### 3. ビルド確認

```bash
bash build.sh
```

コンパイル → .app生成 → ad-hoc署名 → zip + sha256生成まで通ること。
`build/ccglance.app/Contents/Info.plist` の `CFBundleShortVersionString` が新バージョンであること。

### 4. コードレビュー

サブエージェント（`Agent`ツール）に `engineering:code-review` スキルでdiffをレビューさせる。
CHANGELOGエントリと実コミットの整合確認も依頼する。問題があれば修正してから次へ。

### 5. バンプPRの作成

CLAUDE.mdのPR作成ルールに従い、タイトル `Bump version to <VERSION>`、`chore` ラベルでPRを作成する。
Test planには「ビルド成功」「Info.plistのバージョン」「CHANGELOGとPR一覧の整合」の確認済み項目と、
「マージ後にタグをpushしてrelease.ymlの完走を確認」の未了項目を入れる。

このリポジトリはPRに対するCIチェックが無い（release.ymlはタグpushのみ）ので、チェック完了を待たない。

### 6. マージ待ち（ここで停止）

**自分で作成したPRの自動マージは権限で拒否される**。PRのURLを提示してユーザーにマージを依頼し、
タグpush以降の残り手順を伝えて一旦停止する。ユーザーから「マージした」の連絡で再開する。

### 7. タグpush

マージ確認後、**マージ後の `origin/main`** にタグを打つ（ローカルブランチのHEADではない）:

```bash
git fetch origin main
git log origin/main -1 --oneline   # マージコミットであることを確認
git tag v<VERSION> origin/main
git push origin v<VERSION>
```

注意: zshで変数展開のrefspecを使う場合は `${VAR}:refs/...` とブレース必須（`$VAR:r` は
コロン修飾子として解釈され化ける）。上記のようにリテラルで書けば問題ない。

### 8. release.ymlの完走確認

```bash
gh run list --repo hatoya/ccglance --workflow release.yml --limit 1 \
  --json databaseId,status,headBranch --jq '.[0]'      # headBranchがv<VERSION>であること
gh run watch <run-id> --repo hatoya/ccglance --exit-status
```

失敗した場合は原因を調査・修正し、リリースの公開状態で対応を分ける:

- **公開前の失敗**（ビルド失敗等でドラフトのまま or リリース未作成）: 同じタグで再実行できる。
  `gh workflow run release.yml --repo hatoya/ccglance -f tag=v<VERSION>`
  （release.ymlは既存ドラフトの再利用と `--clobber` アップロードに対応している）
- **公開後（`isDraft: false`）の失敗**: 公開済みリリースはimmutableで修正できないため、
  新バージョンのタグでやり直す

### 9. リリース検証（3点セット）

```bash
gh release view v<VERSION> --repo hatoya/ccglance \
  --json isDraft,tagName,assets --jq '{isDraft, tagName, assets: [.assets[].name]}'
gh api repos/hatoya/homebrew-tap/contents/Casks/ccglance.rb \
  --jq '.content' | base64 -d | grep -E 'version|sha256'
```

- リリースが公開済み（`isDraft: false`）
- `ccglance.zip` と `ccglance.zip.sha256` の**両方**が添付されている（アプリ内アップデーターに必須）
- Homebrew tapのcaskが新バージョンとzipのsha256に更新されている
  （`TAP_GITHUB_TOKEN` 未設定時はスキップされるので、その場合は未更新でも正常）

3点そろったらリリース完了。VOICEVOXが起動していれば完了を音声通知する。
