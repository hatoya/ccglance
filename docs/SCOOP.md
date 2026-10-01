# Scoop bucket セットアップ手順

Windows版は個人bucket [hatoya/scoop-bucket](https://github.com/hatoya/scoop-bucket) 経由で [Scoop](https://scoop.sh) からインストールできる（Homebrew tapのWindows版に相当）:

```powershell
scoop bucket add hatoya https://github.com/hatoya/scoop-bucket
scoop install ccglance
```

マニフェスト（`bucket/ccglance.json`）の実体はbucketリポジトリ側にあり、リリースCI（`.github/workflows/release.yml` の `publish` ジョブ）が公開のたびに `version` / `url` / `hash` を自動で書き換える。**この自動更新はGitHub Secret `SCOOP_BUCKET_TOKEN` が設定されている場合のみ動作し、未設定の間はスキップされる**（リリース自体は従来通り成功する）。

## 初回セットアップ

### 1. bucketリポジトリを作る

`hatoya/scoop-bucket` を公開リポジトリとして作成し、`bucket/ccglance.json` を以下の内容で置く（`version` と `hash` は最新リリースの値。`hash` は `ccglance_windows.zip.sha256` アセットの先頭トークン）:

```json
{
  "version": "1.20.0",
  "description": "Always-on-top floating panel showing Claude Code session activity",
  "homepage": "https://github.com/hatoya/ccglance",
  "license": "MIT",
  "url": "https://github.com/hatoya/ccglance/releases/download/v1.20.0/ccglance_windows.zip",
  "hash": "0000000000000000000000000000000000000000000000000000000000000000",
  "extract_dir": "ccglance",
  "bin": "ccglance.exe",
  "shortcuts": [["ccglance.exe", "ccglance"]],
  "notes": [
    "ccglance registers its Claude Code hooks on first launch and updates itself in place.",
    "Before 'scoop uninstall ccglance', quit the app and run: node \"$dir\\hooks\\uninstall.js\""
  ],
  "checkver": "github",
  "autoupdate": {
    "url": "https://github.com/hatoya/ccglance/releases/download/v$version/ccglance_windows.zip",
    "hash": {
      "url": "$url.sha256"
    }
  }
}
```

`checkver` / `autoupdate` はScoopの `checkver.ps1` / `autoupdate` 用で、CIが落ちていても手動 `.\bin\checkver.ps1 ccglance -u` で更新できる。

### 2. SCOOP_BUCKET_TOKEN の設定

リリースワークフローの標準トークン（`github.token`）はccglanceリポジトリにしか書き込めないため、bucketリポジトリへのpush用にfine-grained PATが必要。手順は `docs/HOMEBREW.md` の `TAP_GITHUB_TOKEN` と同じ:

1. [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new) を開く
2. **Repository access**: Only select repositories → `hatoya/scoop-bucket` のみ、**Permissions**: Contents: Read and write
3. ccglanceリポジトリの **Settings → Secrets and variables → Actions** に Name: `SCOOP_BUCKET_TOKEN` で登録する

既存の `TAP_GITHUB_TOKEN` のRepository accessに `hatoya/scoop-bucket` を追加し、同じ値を `SCOOP_BUCKET_TOKEN` にも登録する形でもよい（トークン1本で両方を更新する）。

以降のリリースでは、アセットのアップロード後に「Update Scoop bucket」ステップがマニフェストを自動更新する。動作確認は既存タグへの `workflow_dispatch` でもできるが、**必ず最新リリースのタグを指定すること**（古いタグで実行するとマニフェストがそのバージョンにダウングレードされる）。

## 手動でマニフェストを更新する場合

```bash
TAG=v1.20.0
curl -sL "https://github.com/hatoya/ccglance/releases/download/$TAG/ccglance_windows.zip.sha256" | cut -d' ' -f1
# → bucket/ccglance.json の version（vなし）、url、hash を書き換えてcommit & push
```

## マニフェスト設計のメモ

- `extract_dir: ccglance`: zipは `ccglance/` フォルダをラップしている（macOS版の `--keepParent` と同じ構成）
- インストール先は `~\scoop\apps\ccglance\<version>\` で、`current` ジャンクションが最新を指す。hookのアプリ起動は `~\scoop\apps\ccglance\current\ccglance.exe` も探索するので、アプリが一度も起動していない状態でも `SessionStart` で立ち上がる
- アプリ内アップデーターは `current` が指す実体のexeを差し替える。その後 `scoop update ccglance` を実行するとbucketの版で入れ直される（Homebrewの `auto_updates` に相当する仕組みはScoopに無い）。どちらでも動作に支障はない
- hooks本体は `~\.claude\ccglance\hooks\` にコピーされて動くため、`scoop uninstall` 後もhooksの実行は壊れない。`settings.json` の登録解除は `uninstall.js`（`notes` で案内）。`pre_uninstall` で `uninstall.js` を走らせてはいけない: `scoop update` も旧マニフェストの `pre_uninstall` を実行するので、更新のたびにhooksが解除される
- `bin` はGUIアプリにコンソール用shimを作る。`ccglance` とターミナルから起動できる利点があり、`shortcuts` のスタートメニュー登録と併用している
