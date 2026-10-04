# 以前のHazkey Communityの設定を新バージョンへ移行する

v0.2.30-communityで、インストール先・実行ファイル名・ユーザデータの保存先・サーバソケット名が上流版Hazkeyから分離され、  
名称が**Hazkey Community**に統一されました。  

これに伴い、バージョン 0.2.30より前のバージョンを使用していた場合、設定・ユーザ辞書・ニューラル変換モデル・学習データは自動では引き継がれません。  
本ドキュメントの手順で、1回だけ手動移行してください。  

> パッケージそのものの入れ替え手順 (旧パッケージの削除・新パッケージのインストール) は、  
> [README クイックスタート](../README.md#クイックスタート-github-releasesからインストール)を参照してください。  
> 移行が不要で、旧バージョンが導入したファイルを単に削除したいだけの場合は、  
> [Releaseノート](https://github.com/presire/hazkey-community/releases/tag/v0.2.30-community)の  
> 「以前のHazkey Communityを手動で削除する場合」を参照してください。  

## 前提条件

- 移行スクリプトを実行する前に、**新しいバージョンのHazkey Communityを先にインストール**してください。  
- 移行スクリプトは、旧保存先の設定・ユーザ辞書・ニューラル変換モデル・学習データを新しい保存先へ**コピー**します。  
  旧保存先の内容は変更されません。  
- 起動中のhazkey-community-serverは、スクリプトが終了させます。  
  移行中は、Hazkey Communityで文字を入力しないでください。  

<br>

## 移行手順

1. 新バージョンのインストール直後に作成された、新しい保存先のディレクトリを削除します。  

   ```sh
   rm -rf ~/.local/share/hazkey-community \
          ~/.local/state/hazkey-community \
          ~/.config/hazkey-community
   ```

2. 同梱の移行スクリプトを実行します。  

   ```sh
   /usr/share/hazkey-community/hazkey-community-migrate.sh
   ```

3. 完了後、Fcitx 5 / IBusを再起動し、入力メソッド**Hazkey Community**を追加し直してください。  
   (手順は、[README 初回の有効化](../README.md#初回の有効化)を参照)  

## オプション

| オプション | 内容 |
|:---|:---|
| **`--dry-run`** | 実行内容の確認のみ<br>何も変更せず、サーバも終了しません。 |
| **`--force`** | コピー先に既存ファイルがある場合、`<コピー先>.bak-<日時>`へ退避してからコピーします。 |

```sh
# 実行内容だけを確認したい場合 (サーバは終了しない)
/usr/share/hazkey-community/hazkey-community-migrate.sh --dry-run

# コピー先に既存ファイルがある場合に、退避してから移行する
/usr/share/hazkey-community/hazkey-community-migrate.sh --force
```

## 移行スクリプトの動作

名称変更前のHazkey Community、または上流版Hazkeyで使用していた設定・ユーザ辞書・Zenzaiモデル・学習データが移行対象です。  

- 旧ディレクトリ (`~/.config/hazkey/`、`~/.local/share/hazkey/`、`~/.local/state/hazkey/`、`~/.config/fcitx5/conf/hazkey.conf`) を、  
  Hazkey Community側へ**コピー**します。  
  旧ディレクトリは上流版Hazkeyが引き続き使用するため、変更しません。  
- コピー後、Zenzaiモデルのシンボリックリンク (zenzai.gguf) と、config.json / env内の旧ディレクトリを指すパスを、新ディレクトリへ書き換えます。  
- 起動中のHazkey Community-serverはスクリプトがSIGTERMで終了させ、コピー完了後に再度終了を確認します。  
  Fcitx 5 / IBusがキー入力に応じて再起動するため、移行中はHazkey Communityで文字を入力しないでください。  
- 空のディレクトリだけが作成済みの場合は、サーバが自動作成した未使用の雛形とみなしてデータをコピーします。  
  ファイルやシンボリックリンクを含むコピー先はスキップします。  
  
  `--force`オプションを指定すると、既存のコピー先を`<コピー先>.bak-<日時>`へ退避してからコピーします。  
- Fcitx 5の入力メソッド一覧やIBusの入力ソースは書き換えません。  
  移行後、Fcitx 5 / IBusを再起動し、入力メソッド**Hazkey Community**を追加してください。  

## 関連ドキュメント

- [README 上流版Hazkeyとの併存](../README.md#上流版hazkeyとの併存)  
- [設定・環境のリファレンス](./configuration.md)  
- [トラブルシューティング](./troubleshooting.md)  
- [v0.2.30-community Releaseノート](https://github.com/presire/hazkey-community/releases/tag/v0.2.30-community)  
