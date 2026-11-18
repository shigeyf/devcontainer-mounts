# devcontainer-mounts

[English](./README.md) | [日本語](./README.ja.md)

ホストの `~/.copilot` と `~/.azure` を Dev Container に共有する個人用 Feature です。
プロジェクトの `devcontainer.json` に追加せず、VS Code の User Settings から有効化します。

GitHub Releases の HTTPS tarball で配布します。GHCR、Marketplace、カタログへの登録は不要です。
任意のフォルダーを設定だけで指定する汎用ツールではありません。

## 対応範囲

- WSL2 / Linux と、同じホスト上で動く Docker Engine
- image / Dockerfile / Docker Compose による Dev Container の作成・再構築
- `vscode`、root、独自のホームを持つ別名ユーザー

ローカルのテストでは Debian Bookworm ベースの Dev Container イメージを使用します。
Windows ネイティブ / macOS / リモート Docker ホストは未検証です。

## 使い方

### 1. ホスト側のフォルダーを準備

WSL を使う場合は、コンテナー内ではなく WSL Ubuntu 側で実行します。

```bash
mkdir -p -m 700 "$HOME/.copilot" "$HOME/.azure"
```

既存ディレクトリーの権限は変更しません。マウント元が存在しないとコンテナーの作成に失敗します。

### 2. User Settings に追加

最初に GitHub Releases で `v1.0.0` を公開してください。以下の URL はその Release 公開後に利用できます。

Windows + WSL の構成では、Windows 側 VS Code の利用中の Profile の User Settings に追加します。
コンテナーの Remote Settings や、共有するプロジェクト設定には追加しません。

```json
{
  "dev.containers.defaultFeatures": {
    "https://github.com/shigeyf/devcontainer-mounts/releases/download/v1.0.0/devcontainer-feature-mounts.tgz": {}
  }
}
```

既存の User Settings がある場合は、該当項目だけを追加してください。

### 3. 標準コマンドで再構築

**Dev Containers: Rebuild Container** を実行します。新規の場合は
**Dev Containers: Reopen in Container** を使用します。
作成済みコンテナーへの再接続だけではマウントは変更されません。

### 4. 無効化

User Settings からこの Feature の項目を削除して、標準 Rebuild を実行します。
ホスト側のデータは削除されません。
プロジェクト自身が別途定義しているマウントは、この操作では無効になりません。

## 仕組み

| ホスト | コンテナー内の bind mount | 利用時のパス |
| --- | --- | --- |
| `${localEnv:HOME}/.copilot` | `/mnt/mounts/.copilot` | 実効ユーザーの `~/.copilot` |
| `${localEnv:HOME}/.azure` | `/mnt/mounts/.azure` | 実効ユーザーの `~/.azure` |

マウントは `devcontainer-feature.json` が定義します。
`install.sh` は、ビルド時には汎用の `link-mounts.sh` を配置するだけです。
マウントが利用可能になる作成後の `onCreateCommand` で、このスクリプトを実効ユーザーとして実行します。
`/mnt/mounts` 直下の実際にマウントされたフォルダーだけを確認し、`$HOME` に同名の symlink を作ります。
通常のディレクトリー・ファイル・symlink は対象にしません。マウントがない場合は、その旨をログに出して終了します。
`/home/vscode` や `/root` を固定しないため、別名ユーザーや独自ホームにも対応します。
コンテナー内に jq 等の JSON 解析ツールは不要ですが、util-linux の `mountpoint` が必要です。
Feature の `onCreateCommand` はプロジェクト自身の `onCreateCommand` より前に実行されます。
ビルド中の他の Feature のインストール処理からは、ホームの symlink はまだ利用できません。

マウントとホーム側の接続を確認するには、コンテナー内で次を実行します。

```bash
readlink "$HOME/.copilot"
readlink "$HOME/.azure"
mountpoint /mnt/mounts/.copilot
mountpoint /mnt/mounts/.azure
```

## 注意事項

- 両フォルダーは読み書き可能です。コンテナー内のプロセスはホストの認証情報・履歴・設定を変更できます。信頼するプロジェクトだけで使用してください。
- ホームに既存の `.copilot` / `.azure`、または別の symlink がある場合、上書きせず明示エラーにします。認証データを安易に削除しないでください。
- ホストの所有者・権限を変更しません。root コンテナーが新規作成するファイルは root 所有になる場合があります。
- ディレクトリー共有はログインの引き継ぎを保証しません。OS の keychain、認証方式、アプリケーションのバージョンに依存します。
- 履歴や DB を複数プロセスで共有する際の排他制御は、それぞれのアプリケーションに依存します。
- フォルダーを追加する場合は、metadata の `mounts` に追加して新しいバージョンで公開してください。`install.sh` と `link-mounts.sh` の変更は不要です。
- `target` は `/mnt/mounts/<フォルダー名>` とします。同じ名前のリンクをユーザーのホーム直下に作ります。空白を含む名前にも対応しますが、階層を含む名前・`.`・`..`・制御文字・重複 target は受け付けません。
- 実際の `.copilot` / `.azure`、トークン、設定ファイルの内容をこのリポジトリへ入れないでください。

## 開発・ローカル検証

ホスト側に Bash、Docker、jq、GNU tar、sha256sum が必要です。
テストはホストの一般ユーザーで実行します。Docker daemon は同じホストで動作させてください。

```bash
bash tests/test.sh
```

テストは一時領域のダミーデータのみを使い、実際の `~/.copilot` / `~/.azure` は読みません。
配布用 tarball の内容と実行権限、チェックサム、３ユーザーのホーム接続・読み書き、
ビルド時にマウントが不要であること、作成後フックの再実行、マウント以外の除外、既存ディレクトリーと競合 symlink の保護を確認します。
さらに、一時的な metadata に空白を含むフォルダーを追加し、スクリプトを変更せず３ユーザーで利用できることを確認します。
実際のマウント元はすべてダミーの一時フォルダーに置き換えます。
コンテナーは終了時に削除され、一時ファイルも片付けます。

このテストは installer と、実際の bind mount に対して実効ユーザーで実行する作成後フックを検証します。
VS Code の User Settings から公開 URL を取得する E2E は、Release 公開後に別途確認してください。

パッケージだけを作る場合:

```bash
bash scripts/package.sh
```

生成物:

```text
dist/devcontainer-feature-mounts.tgz
dist/devcontainer-feature-mounts.tgz.sha256
```

tarball のルートには、metadata、実行可能な `install.sh` と `link-mounts.sh` が含まれます。
追加のマウント一覧ファイルは生成しません。
生成物や認証ファイルは Git 管理対象に含めません。

## GitHub Releases への公開

1. 必要な変更を commit し、リポジトリのデフォルトブランチへ自分で push します。
2. Actions の **Test** が成功することを確認します。
3. Actions の **Release → Run workflow** をデフォルトブランチで実行します。
4. テスト成功後、Feature の `version` からタグを作成し、tarball とチェックサムを Release に添付します。
5. アセットのアップロードが完了してから、draft を公開状態に切り替えます。

最初のバージョンは `1.0.0`、タグは `v1.0.0` です。
手動で先にタグを push する必要はありません。公開ワークフローがタグを作成します。
デフォルトブランチ以外で実行した場合、公開ジョブはスキップされます。

追加の PAT や GHCR 認証は不要です。ワークフローは組み込みの `GITHUB_TOKEN` と
`contents: write` 権限を使用します。リポジトリでは GitHub Actions を有効にしてください。

既存のタグ・Release・アセットは自動上書きしません。
公開処理が途中で失敗した場合は、残ったタグや draft を確認してから対応してください。
ワークフローはそれらを自動削除・上書きしません。

更新時は metadata の `version` を新しい `MAJOR.MINOR.PATCH` に変更して再公開し、
User Settings の URL も新しいタグへ更新します。同じバージョンのアセットを差し替えないでください。
