# notarization セットアップ手順

ccglanceのリリースCI（`.github/workflows/release.yml`）は、以下のGitHub Secretsが設定されている場合のみDeveloper ID署名 + Apple公証（notarization）+ stapleを自動実行する。**未設定の間は従来通りad-hoc署名のままリリースされる**ため、この手順は準備ができたタイミングで進めればよい。

有効化すると、ユーザーはダウンロードした`ccglance.app`を右クリック→「開く」の回避手順なしでそのまま起動できるようになる。

## 必要なもの

| 項目 | 用途 |
|---|---|
| Apple Developer Program（年額$99） | Developer ID証明書とnotarizationの前提 |
| Developer ID Application証明書（.p12） | CIでのコード署名 |
| App Store Connect APIキー（.p8） | CIからのnotarytool認証 |

## 1. Apple Developer Programに登録する

1. [developer.apple.com/programs/enroll](https://developer.apple.com/programs/enroll/) からApple IDで登録する（個人開発者として登録可能）
2. 年額$99（約15,000円）。支払い後、承認まで通常は即日〜48時間程度
3. 承認されると [developer.apple.com/account](https://developer.apple.com/account) にアクセスできるようになる

## 2. Developer ID Application証明書を作成する

1. Macの**キーチェーンアクセス**を開き、メニュー「キーチェーンアクセス → 証明書アシスタント → 認証局に証明書を要求…」を選択
   - メールアドレス: Apple IDのメールアドレス
   - 通称: 任意（例: `hatoya Developer ID`）
   - 「ディスクに保存」を選び、CSRファイル（`.certSigningRequest`）を保存
2. [developer.apple.com/account/resources/certificates/add](https://developer.apple.com/account/resources/certificates/add) で **Developer ID Application** を選択し、CSRをアップロードして証明書（`.cer`）をダウンロード
3. ダウンロードした`.cer`をダブルクリックしてキーチェーン（ログイン）に取り込む
4. キーチェーンアクセスの「自分の証明書」で `Developer ID Application: <名前> (<Team ID>)` を右クリック → 「書き出す…」→ フォーマット「個人情報交換（.p12）」で保存し、書き出し用パスワードを設定する（このパスワードが `MACOS_CERTIFICATE_PASSWORD` になる）
5. base64化してクリップボードへ:

   ```bash
   base64 -i DeveloperID.p12 | pbcopy
   ```

## 3. App Store Connect APIキーを作成する

> **注意: 必ず「チームキー」を作成すること。** 「個人キー（Individual API Key）」はIssuer IDを持たず、CIが使う`notarytool --issuer`と非互換。

1. [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api) を開く（「ユーザとアクセス → 統合 → App Store Connect API → チームキー」）
2. 「APIキーを生成」でキーを作成する。アクセス権は **Developer** 以上
3. 以下の3点を控える:
   - **Issuer ID**（ページ上部に表示されるUUID）→ `APPLE_API_ISSUER_ID`
   - **キーID**（例: `2X9R4HXF34`）→ `APPLE_API_KEY_ID`
   - **APIキーのダウンロード**（`AuthKey_XXXXXXXXXX.p8`）→ 中身が `APPLE_API_KEY_P8`
     - **ダウンロードは1回しかできない**ので安全な場所に保管する

## 4. GitHub Secretsを登録する

リポジトリの Settings → Secrets and variables → Actions、または`gh`で:

```bash
base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12
gh secret set MACOS_CERTIFICATE_PASSWORD   # .p12書き出し時のパスワードを入力
gh secret set APPLE_API_KEY_P8 < AuthKey_XXXXXXXXXX.p8
gh secret set APPLE_API_KEY_ID --body "2X9R4HXF34"
gh secret set APPLE_API_ISSUER_ID --body "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

| Secret | 内容 |
|---|---|
| `MACOS_CERTIFICATE_P12` | Developer ID Application証明書（.p12）のbase64 |
| `MACOS_CERTIFICATE_PASSWORD` | .p12の書き出しパスワード |
| `APPLE_API_KEY_P8` | APIキー（.p8）のテキスト内容そのまま |
| `APPLE_API_KEY_ID` | APIキーのキーID |
| `APPLE_API_ISSUER_ID` | チームのIssuer ID |

部分的に設定した場合の挙動:

- 証明書系（`MACOS_CERTIFICATE_*`）のみ → Developer ID署名はされるがnotarizeなし（Gatekeeper回避効果はないため、5つ揃えること）
- APIキー系（`APPLE_API_*`）のみ → ad-hoc署名アプリはnotarize不可のため、notarizeは自動的にスキップされ従来通りのリリースになる

## 5. 動作確認

1. `release.yml`を`workflow_dispatch`で既存タグに対して手動実行するか、次のリリースを公開する
2. Actionsのログで以下を確認:
   - `Import signing certificate` ステップが実行されている（スキップされていない）
   - Buildステップに `Notarizing…` → `status: Accepted` → `Stapling…` が出ている
3. リリースアセットの`ccglance.zip`をブラウザでダウンロードして検証:

   ```bash
   unzip ccglance.zip
   spctl -a -vv ccglance.app
   # → "accepted / source=Notarized Developer ID" ならOK
   xcrun stapler validate ccglance.app
   # → "The validate action worked!" ならOK
   ```

4. `README.md`はnotarize前提の記載に更新済み（Gatekeeperの右クリック回避注記は削除済み）。今後ad-hocに戻す場合のみ注記を復活させる

## トラブルシュート

- **`security import`が`MAC verification failed during PKCS12 import (wrong password?)`で失敗する**: パスワードは正しいのに出る場合、`openssl pkcs12 -export`（OpenSSL 3.x）が.p12をSHA256 MAC + AES-256（PBES2）形式で作っており、macOSの`security`が非対応なのが原因。`openssl pkcs12 -export -legacy ...`で作り直す（MAC sha1 + 3DES/RC2になりmacOS互換）。`openssl pkcs12 -in x.p12 -info -passin pass:... -noout | grep -iE 'MAC:|PBE'`で`MAC: sha256`なら要`-legacy`。作り直したら`MACOS_CERTIFICATE_P12`だけ更新すればよい（同じパスワードを再利用すれば`MACOS_CERTIFICATE_PASSWORD`は据え置き可）。※キーチェーンアクセスのGUIから書き出した.p12はこの問題は起きない
- **codesignが「unable to build chain」で失敗する**: Apple中間証明書が不足している。[Apple PKI](https://www.apple.com/certificateauthority/)から「Developer ID - G2」CA証明書をダウンロードし、`Import signing certificate`ステップ内で一時keychainに`security import`する1行を追加する
- **notarizationが`Invalid`になる**: CIログに`notarytool log`の出力（JSON）が出るので、`issues`配列の内容を確認する
- **初回のnotarizeが異常に長い**: 新規Developerアカウントの初回申請はAppleの審査で数時間保留されることがある。ジョブの`--timeout 30m`を超えて失敗した場合は時間を置いて`workflow_dispatch`で再実行する
- **stapleが失敗する**: チケットのCDN反映遅延。ビルドスクリプトが10秒間隔で5回リトライするので通常は自然回復する
