# Homebrew tap セットアップ手順

ccglanceは個人tap [hatoya/homebrew-tap](https://github.com/hatoya/homebrew-tap) 経由でHomebrewからインストールできる:

```bash
brew install --cask hatoya/tap/ccglance
```

cask定義（`Casks/ccglance.rb`）の実体はtapリポジトリ側にあり、リリースCI（`.github/workflows/release.yml`）が公開のたびに `version` と `sha256` を自動で書き換える。**この自動更新はGitHub Secret `TAP_GITHUB_TOKEN` が設定されている場合のみ動作し、未設定の間はスキップされる**（リリース自体は従来通り成功する）。

## TAP_GITHUB_TOKEN の設定

リリースワークフローの標準トークン（`github.token`）はccglanceリポジトリにしか書き込めないため、tapリポジトリへのpush用にfine-grained PATが必要。

1. [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new) を開く
2. 以下で作成する:
   - **Token name**: `ccglance-homebrew-tap` など
   - **Expiration**: 任意（失効時はこの手順で再発行して差し替える）
   - **Repository access**: Only select repositories → `hatoya/homebrew-tap` のみ
   - **Permissions**: Repository permissions → **Contents: Read and write**（それ以外は不要）
3. 生成されたトークン（`github_pat_…`）をコピーする
4. ccglanceリポジトリの **Settings → Secrets and variables → Actions → New repository secret** で、Name: `TAP_GITHUB_TOKEN`、Secret: コピーしたトークン、として登録する

以降のリリースでは、アセットのアップロード後に「Update Homebrew tap」ステップがtapのcaskを自動更新する。動作は既存タグへの `workflow_dispatch` 実行でも確認できるが、**必ず最新リリースのタグを指定すること**（古いタグで実行するとcaskがそのバージョンにダウングレードされ、再ビルドされたzipで既存リリースのアセットも上書きされる）。

## 手動でcaskを更新する場合

CIが使えないときは、リリース済みの `.sha256` アセットの値でtapリポジトリの `Casks/ccglance.rb` の2行を書き換えてpushする:

```bash
TAG=v1.3.0
curl -sL "https://github.com/hatoya/ccglance/releases/download/$TAG/ccglance.zip.sha256" | cut -d' ' -f1
# → Casks/ccglance.rb の version（vなし）と sha256 を書き換えてcommit & push
```

## cask設計のメモ

- `auto_updates true`: アプリ内アップデーターが自前で `.app` を置き換えるため、`brew upgrade` の一括更新対象から外している（`--greedy` 指定時のみbrewが更新する）
- `depends_on arch: :arm64`: リリースバイナリはarm64のみ（macos-14ランナーでビルド）
- hooks本体は `~/.claude/ccglance/hooks/` にコピーされて動くため、brewでアプリを削除してもhooksの実行は壊れない。`~/.claude/settings.json` の登録解除は `uninstall.js`（caveatsに案内あり）、データ削除は `brew uninstall --zap` が `~/.claude/ccglance` を削除する
