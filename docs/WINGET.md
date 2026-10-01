# winget セットアップ手順

Windows版は [winget](https://learn.microsoft.com/windows/package-manager/) の公式リポジトリ [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) に `hatoya.ccglance` として登録すると、追加設定なしでインストールできる:

```powershell
winget install hatoya.ccglance
```

マニフェストはwinget-pkgs側にあり、更新はPRで行う。リリースCI（`.github/workflows/release.yml` の `publish` ジョブ末尾）が公開後に [winget-releaser](https://github.com/vedantmgoyal9/winget-releaser) でバージョン更新PRを自動作成する。**これはGitHub Secret `WINGET_TOKEN` が設定されている場合のみ動作し、未設定の間はスキップされる**。また、**初回登録は手動**（パッケージが存在しないとwinget-releaserは更新できない）。

## 初回登録（手動）

1. Windows機で [wingetcreate](https://github.com/microsoft/winget-create) を入れる: `winget install wingetcreate`
2. 最新リリースのzip URLからマニフェストを対話生成する:

   ```powershell
   wingetcreate new https://github.com/hatoya/ccglance/releases/download/v1.20.0/ccglance_windows.zip
   ```

   聞かれる項目の要点:
   - **PackageIdentifier**: `hatoya.ccglance`、**PackageVersion**: `1.20.0`
   - **InstallerType**: `zip`、**NestedInstallerType**: `portable`
   - **NestedInstallerFiles → RelativeFilePath**: `ccglance\ccglance.exe`、**PortableCommandAlias**: `ccglance`
   - **Publisher**: `hatoya`、**PackageName**: `ccglance`、**License**: `MIT`、**ShortDescription**: `Always-on-top floating panel showing Claude Code session activity`
   - **PackageUrl / PublisherUrl**: `https://github.com/hatoya/ccglance`
3. 生成された `manifests/h/hatoya/ccglance/1.20.0/` の3ファイル（`hatoya.ccglance.yaml` / `hatoya.ccglance.installer.yaml` / `hatoya.ccglance.locale.en-US.yaml`）を確認し、`wingetcreate submit` でwinget-pkgsにPRを出す（GitHubトークンを求められる）
4. winget-pkgsのCI（マニフェスト検証・インストールテスト）とモデレーターのレビューを通過するとマージされ、数時間後に `winget install hatoya.ccglance` が通るようになる

参考: installer マニフェストの要点

```yaml
PackageIdentifier: hatoya.ccglance
PackageVersion: 1.20.0
InstallerType: zip
NestedInstallerType: portable
NestedInstallerFiles:
  - RelativeFilePath: ccglance\ccglance.exe
    PortableCommandAlias: ccglance
Installers:
  - Architecture: x64
    InstallerUrl: https://github.com/hatoya/ccglance/releases/download/v1.20.0/ccglance_windows.zip
    InstallerSha256: <ccglance_windows.zip.sha256 の値を大文字で>
ManifestType: installer
ManifestVersion: 1.10.0   # wingetcreate が生成した値のまま使う
```

## WINGET_TOKEN の設定

winget-releaserはトークンの持ち主のアカウントにある `winget-pkgs` のフォークからPRを作る（`fork-user` 未指定時はリポジトリオーナー `hatoya` のフォークを使う）。

1. トークンの持ち主のアカウントで `microsoft/winget-pkgs` をフォークしておく（必須。フォークが無いと失敗する）
2. [github.com/settings/tokens/new](https://github.com/settings/tokens/new) で **classic** PAT を作る。Scope: `public_repo`（winget-releaserはfine-grained PATに対応していない）
3. ccglanceリポジトリの **Settings → Secrets and variables → Actions** に Name: `WINGET_TOKEN` で登録する

以降のリリースでは、`publish` ジョブの最後に `hatoya.ccglance` の新バージョンPRが作成される。マージはwinget-pkgs側の自動CIとモデレーターが行う。

## 設計メモ

- portable型なので `winget install` はzipをユーザー領域（`%LOCALAPPDATA%\Microsoft\WinGet\Packages\<PackageIdentifier>_<ソース名>\` 配下）に展開し、`%LOCALAPPDATA%\Microsoft\WinGet\Links\ccglance.exe` にコマンドエイリアスを作る。書き込める場所なのでアプリ内アップデーターもそのまま動く。hookのアプリ起動はこの `Links` パスも探索する
- アプリ内アップデーターで先に更新されていても、`winget upgrade` はマニフェストの版で入れ直す。動作に支障はない
- hooksの解除は `uninstall.js`。`winget uninstall hatoya.ccglance` はファイルを消すだけなので、先にアプリを終了して `node "<インストール先>\hooks\uninstall.js"` を実行する
