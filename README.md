# Hazkey Community

[![based on 7ka-Hiira/hazkey](https://img.shields.io/badge/based%20on-7ka--Hiira%2Fhazkey-blue)](https://github.com/7ka-Hiira/hazkey)
[![Fcitx 5](https://img.shields.io/badge/Fcitx%205-support-blue)](https://fcitx-im.org/)
[![IBus](https://img.shields.io/badge/IBus-experimental-orange)](https://github.com/ibus/ibus)

Hazkey Communityは、Linux向けデスクトップ環境のインプットメソッドフレームワーク[Fcitx 5](https://fcitx-im.org/) および [IBus](https://github.com/ibus/ibus)で動作する日本語インプットメソッドです。  
[AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)を変換エンジンに採用し、  
オプションでニューラル変換 (Zenzai、llama.cppバックエンド、Vulkan GPU / CPU対応) を利用でき、標準のzenz系列に加えてQwen3ベースの**jinen-v2**モデルにも対応しています。  

Fcitx 5フロントエンド (fcitx5-hazkey-community) に加えて、実験的なIBusフロントエンド (ibus-hazkey-community) を同梱します。  

> IBus版をソースコードからビルドする場合は、CMakeで `ENABLE_IBUS` オプションが必要です。(デフォルトはOFF)  
> バイナリパッケージは両フロントエンド分を頒布します。  

本リポジトリは [7ka-Hiira/hazkey](https://github.com/7ka-Hiira/hazkey) をベースにしたコミュニティ版で、現在のバージョンは **v0.2.31** です。  

> **上流版 (hazkey公式) の情報**  
> - ホームページ: [https://hazkey.hiira.dev](https://hazkey.hiira.dev)  
> - ドキュメント: [https://hazkey.hiira.dev/docs](https://hazkey.hiira.dev/docs)  

<br>

## 対応環境

| 区分 | ディストリビューション |
|---|---|
| **動作確認・サポート対象** | Fedora 44<br>openSUSE Leap 16<br>Debian 13 (Trixie) x64 |
| **CIビルド・パッケージ頒布対象** (動作確認・サポート対象外) | 上記に加えて、<br>Debian 13 (Trixie) AArch64<br>Ubuntu 26.04<br>openSUSE Tumbleweed |

- パッケージの頒布は、その環境での動作保証を意味しません。  
- その他のディストリビューションでの動作は保証しません。  
- 上流版の対応環境・インストール方法については、[上流ドキュメント](https://hazkey.hiira.dev/docs) を参照してください。  

<br>

## コミュニティ版の主な機能 (v0.2.2-community以降)

上流に対するコミュニティ版独自の追加機能・改善の概要です。  

| 機能 | 内容 |
|---|---|
| ユーザ辞書 (品詞・動詞活用対応) | TSV形式 (`読み<TAB>単語<TAB>コメント[<TAB>品詞]`) で単語を登録できる辞書<br>品詞 (固有名詞・人名・地名・動詞) を指定すると変換エンジンの接続コスト評価に品詞が反映される。<br>設定UIの辞書タブから追加・編集・インポート・エクスポートが可能 |
| 動詞活用エンジン | azooKeyの `JapaneseConjugationBuilder` を移植<br>ユーザ辞書に登録した動詞から全活用形を自動生成し、五段活用・一段活用・サ行変格に対応 |
| 文節境界調整 | 変換中に `Shift+Left` / `Shift+Right` で文節の境界を直接調整できる |
| ライブ変換トグル | `Ctrl+Shift+L` (デフォルト、設定で変更可能) でライブ変換のON / OFFを即座に切替え<br>OFF時のモードは記憶され、アプリ間の切替をまたいで維持される |
| 予測候補の先頭表記固定 | サジェスト候補にカーソルを合わせて `F5` (変更可能) を押すと、その表記を先頭の固定表記として受理しつつ続きを入力できる |
| 学習データの削除・履歴管理 | 候補フォーカス中に `Ctrl+D` (設定で変更可能、「候補学習削除ホットキー」) でその候補の学習データを削除<br>設定UIの「入力履歴データの管理」から入力履歴を選択して削除するダイアログも利用可能 |
| Emoji 17直接変換 | Emoji 17.0辞書による絵文字の直接変換候補を追加 (設定UI「拡張絵文字」、デフォルトON)<br>通常変換の候補にのみ注入され、サジェスト・ライブ変換には混入しない |
| 日本全国の地名辞書 | 都道府県・郡・市区町村・町域/大字のうち、変換エンジンが一発変換できない難読地名47,934件を組み込み辞書として収録 (設定UIの[変換]タブ「住所辞書」、デフォルトOFF)<br>一発変換できる地名は収録しないため、通常の変換候補の順位に影響しない |
| 工学用語辞書 | 機械・電気・電子・情報工学、情報系サービス名、プログラム言語、データベース名、建築学、土木工学等の専門用語・名称のうち、変換エンジンが一発変換できないもの859件を組み込み辞書として収録 (設定UIの[変換]タブ「工学用語」、デフォルトOFF)<br>「住所辞書」とは独立にON / OFFできる<br>読み・表記の出典は SudachiDict (Apache-2.0) ほか ([hazkey-engineering-dictionary](https://github.com/presire/hazkey-engineering-dictionary) の NOTICE 参照) |
| 候補ウィンドウのマウス選択 | 変換候補ウィンドウの候補をマウスクリックでも選択できる |
| ニューラル変換設定の拡充 (Zenzai) | プロファイルごとのトピック・文体・好みの指定、任意のGGUFファイルのカスタムモデル指定、リッチ候補の候補一覧 / サジェスト個別切替、GUIからのニューラル変換モデル管理 (ダウンロード・有効化・削除) |
| 複数のニューラル変換モデルに対応 (zenz / jinen-v2) | 標準の **zenz** 系列 (Apache-2.0 / CC-BY-SA-4.0) に加え、[togatogah](https://huggingface.co/togatogah) 氏が公開する Qwen3 ベースの **jinen-v2** (small / xsmall、量子化 `f16`/`Q8_0`/`Q5_K_M`/`Q4_K_M` を選択可、CC-BY-SA-4.0) に対応<br>設定UIの表記もモデルに依存しない「ニューラル変換」に統一<br>jinen系モデルはプロファイル・トピック・文体・好み (条件トークン) に対応しないため、有効化中は該当欄が自動的にグレーアウトされる |
| ニューラル変換の事前ウォームアップ | サーバ起動時と設定の適用後にモデルを事前ロードし、初回入力時のモデルロード待ちを解消 |
| プロファイルごとの履歴分離 | [プロファイル非依存の入力履歴]を無効にすると、プロファイルごとに学習データを分離して保存できる |
| サーバ管理の安定化 | クライアント更新時のhazkey-community-server自動再起動、不正設定ファイルの安全なパース、サーバプロセス管理の改善 |
| マルチGPU環境のSIGILL回避 | NVIDIAとAMD/Intel iGPUが同居する環境での起動時クラッシュ ([上流 Issue #29](https://github.com/7ka-Hiira/hazkey/issues/29)) を、隔離子プロセスによる起動前のバックエンド安全確認とCPU専用への自動フォールバックで解消<br>(フォールバック発生時は設定UIの[AI]タブに警告を表示。下記[トラブルシューティング](./docs/troubleshooting.md)参照) |

<br>

## クイックスタート (GitHub Releasesからインストール)

サポート対象環境では、ソースビルド不要でGitHub Releasesのパッケージをインストールできます。  

1. [Releases ページ](https://github.com/presire/hazkey-community/releases) から最新版 (**v0.2.20-community**以降) を開きます。  
2. お使いのディストリビューション向けのアーカイブ (`.deb` または `.rpm`) をダウンロードします。  
   パッケージは、Debian 13 / Ubuntu 26.04向けに `.deb`、Fedora 44 / openSUSE Leap 16 / Tumbleweed 向けに `.rpm` が頒布されます。  
   
   フロントエンドごとにパッケージが分かれています。(fcitx5-hazkey-community: Fcitx 5用、ibus-hazkey-community: IBus用)  
   
   使用するフレームワークのパッケージを選んでください。  
   両方入れておくこともできます。(Fcitx 5とIBusを同時に有効化して使用できます。下記の「IBus フロントエンドの既知の制約」参照)  
   
   - Debian / Ubuntu (`.deb`):  
     両パッケージは共有ファイル (`hazkey-community-server` / `hazkey-community-settings` / 辞書等) を相互に上書きできるよう `Replaces` を宣言しており、  
     どちらの順に入れても共存できます。  
   - RPM (`.rpm`):  
     追加の宣言なしに共存できます。  
   
   両フロントエンドのパッケージは同じバージョンで揃えて使用してください。(異なるバージョンの混在は非サポートです)  
   
   > **共有ファイルの扱い (Debian / Ubuntu)**:  
   > 両パッケージは `/usr/bin/hazkey-community-server` 等の共有ファイルを同じパスに含みます。  
   > dpkgは共有ファイルを「最後にインストールした側」の所有として扱うため、  
   > 後から入れた側を `apt remove` / `dpkg -r` すると、残した側の共有ファイルも一緒に削除されます。  
   > 残す側のパッケージを再インストール (例: `sudo apt install --reinstall ./fcitx5-hazkey-community_*_amd64.deb`) すると復旧します。  
   > RPM (`.rpm`) では、片方を削除してももう片方が残っていれば共有ファイルは削除されません。  
3. ダウンロードしたパッケージをインストールします。(パスはダウンロード先に合わせてください)  
   
   ```sh
   # Fedora (使用するフレームワークのパッケージを指定。例は両方)
   sudo dnf install ./fcitx5-hazkey-community-*.rpm ./ibus-hazkey-community-*.rpm
   
   # openSUSE (使用するフレームワークのパッケージを指定。例は両方)
   sudo zypper install ./fcitx5-hazkey-community-*.rpm ./ibus-hazkey-community-*.rpm
   
   # Debian / Ubuntu系 (使用するフレームワークのパッケージを指定。例は両方)
   sudo apt install ./fcitx5-hazkey-community_*_amd64.deb ./ibus-hazkey-community_*_amd64.deb
   ```
   
4. 使用しているフレームワークを再起動します。  
   (Fcitx 5はログアウト / ログイン、または下記の「初回の有効化」の手順。IBusは、`ibus restart` 等)  

> インストール後、設定UI (hazkey-community-settings) と サーバ (hazkey-community-server) は同じバージョンで揃います。  
> クライアントとサーバのバージョンが不一致になった場合は、hazkey-community-server が自動的に再起動されます。  

### ダウンロードの検証 (SHA-256・GPG署名)

Releasesページにはパッケージと合わせて `SHA256SUMS` が置かれています。  
ダウンロード後は、次の手順で破損・改竄の有無を確認できます。  

```sh
# .deb / .rpmと同じディレクトリにSHA256SUMSを配置して実行
sha256sum -c SHA256SUMS
```

RPMパッケージはGPG署名付きで頒布されています。(DEBは署名検証を行わないため不要です)  
初回に1回だけ公開鍵 (`RPM-GPG-KEY-hazkey`、Releasesページから取得) を登録すると、  
以降のdnf / zypperでのインストール時に署名警告が表示されなくなります。  

```sh
# 公開鍵の登録 (初回のみ)
sudo rpm --import RPM-GPG-KEY-hazkey

# 署名の確認 (任意)
rpm -K ./fcitx5-hazkey-community-*.rpm ./ibus-hazkey-community-*.rpm
```

ビルドの来歴証明 (Artifact Attestation) も付与されています。  
ghコマンドがある環境では、次のコマンドで「このCIでビルドされた」ことを検証 (任意) できます。  

```sh
gh attestation verify ./fcitx5-hazkey-community-*.rpm ./ibus-hazkey-community-*.rpm --owner presire
```

<br>

## 以前のバージョンからのアップグレード

v0.2.30-community で、インストール先・実行ファイル名・ユーザデータの保存先・サーバソケット名が上流版Hazkeyから分離され、  
名称が **Hazkey Community** に統一されました。  
v0.2.30-communityより前のバージョンからアップグレードする場合は、パッケージの入れ替えと設定の移行が必要です。  

- パッケージ名が変更されたため、旧パッケージからの上書き更新はできません。  
  旧パッケージを削除してから、新しいパッケージをインストールしてください。  
- 既存の設定・ユーザ辞書・ニューラル変換モデル・学習データは自動では引き継がれません。  
  引き継ぐ場合は、[docs/migration.md](./docs/migration.md) の手順で1回だけ手動移行してください。  
- 入力メソッドの登録名も変更されるため、インストール後にFcitx 5 / IBusを再起動し、  
  あらためて **Hazkey Community** を追加し直してください。(下記「初回の有効化」参照)  

<br>

## 初回の有効化

### Fcitx 5に登録

1. Fcitx 5を再起動します。  
   
   ```sh
   systemctl --user restart fcitx5.service
   # または fcitx5 を終了してから再度起動
   ```
   
2. Fcitx 5の設定ツール (タスクトレイアイコンから[設定]、または `fcitx5-configtool`) を開き、入力メソッドの追加から**Hazkey Community**を登録します。  
3. 入力メソッドの切替 (デフォルトでは、`[Super] + [Space]` 等、Fcitx 5側の設定に依存) でHazkey Communityに切り替え、ローマ字入力してかなが変換できることを確認します。  
4. 設定を変更する場合は、アプリケーションメニューまたはターミナルから **hazkey-community-settings** を起動します。  
   
   ```sh
   hazkey-community-settings
   ```

### IBusに登録 (実験的)

1. ibus-daemonを再起動します。  
   
   ```sh
   ibus restart
   # またはログアウト / ログイン
   ```
   
2. ibus list-engineに**Hazkey Community**が表示されることを確認します。  
   
   ```sh
   ibus list-engine | grep hazkey-community
   ```
   
3. デスクトップ環境の入力ソース設定 (GNOME の[設定]→[キーボード]→[入力ソース]等) または `ibus-setup` から**Hazkey Community**を追加します。  
4. 入力メソッドの切替 (デフォルトでは `Super+Space` 等、環境の設定に依存) でHazkey Communityに切り替え、ローマ字入力してかなが変換できることを確認します。  
5. 設定を変更する場合は、アプリメニューまたはターミナルから **hazkey-community-settings** を起動します。  
   
   ```sh
   hazkey-community-settings
   ```

<br>

## 上流版Hazkeyとの併存・データ移行

Hazkey Communityは、インストール先・実行ファイル名・ユーザデータのディレクトリ・ソケット名を上流版Hazkeyと分けているため、  
上流版Hazkey (`fcitx5-hazkey` / `ibus-hazkey`) と同時にインストールできます。  
入力メソッド名も別 (Fcitx 5: **Hazkey Community**、IBus: **Hazkey Community**) で、互いのサーバや設定には干渉しません。  

| 用途 | 上流版Hazkey | Hazkey Community |
|---|---|---|
| サーバ / 設定UI | `/usr/bin/hazkey-server`<br>`/usr/bin/hazkey-settings` | `/usr/bin/hazkey-community-server`<br>`/usr/bin/hazkey-community-settings` |
| プログラム / データ | `/usr/lib*/hazkey/`<br>`/usr/share/hazkey/` | `/usr/lib*/hazkey-community/`<br>`/usr/share/hazkey-community/` |
| Fcitx 5アドオン | `fcitx5-hazkey.so`<br>`addon/hazkey.conf`・`inputmethod/hazkey.conf` | `fcitx5-hazkey-community.so`<br>`addon/hazkey-community.conf`・`inputmethod/hazkey-community.conf` |
| IBusエンジン | `ibus-hazkey.xml`<br>`libexec/ibus-hazkey/ibus-engine-hazkey` | `ibus-hazkey-community.xml`<br>`libexec/ibus-hazkey-community/ibus-engine-hazkey-community` |
| ユーザデータ | `~/.config/hazkey/`<br>`~/.local/share/hazkey/`<br>`~/.local/state/hazkey/` | `~/.config/hazkey-community/`<br>`~/.local/share/hazkey-community/`<br>`~/.local/state/hazkey-community/` |
| サーバソケット | `$XDG_RUNTIME_DIR/hazkey-server.<uid>.sock` | `$XDG_RUNTIME_DIR/hazkey-community-server.<uid>.sock` |

> 実行ファイル名 `hazkey-community-server` は15文字を超えるため、`pgrep -x` / `pkill -x` (プロセス名の完全一致) では一致しません。  
> サーバを終了する場合は、次のようにコマンドライン照合 (`-f`) を使用してください。  
>
> ```sh
> pkill -u $USER -f '^([^ ]*/)?hazkey-community-server( |$)'
> ```

### 既存データの移行 (手動)

名称変更前のHazkey Community、または上流版Hazkeyで使用していた設定・ユーザ辞書・Zenzaiモデル・学習データは、自動では引き継がれません。  
引き継ぐ場合は、同梱の移行スクリプトを手動で1回実行します。  

```sh
# 実行内容の確認のみ (何も変更しない)
# dry-runはサーバを終了しない
/usr/share/hazkey-community/hazkey-community-migrate.sh --dry-run

# 移行を実行する
/usr/share/hazkey-community/hazkey-community-migrate.sh
```

- 旧ディレクトリ (`~/.config/hazkey/`、`~/.local/share/hazkey/`、`~/.local/state/hazkey/`、`~/.config/fcitx5/conf/hazkey.conf`) を、  
  Hazkey Community側へ**コピー**します。  
  旧ディレクトリは上流版Hazkeyが引き続き使用するため、変更しません。  
- コピー後、Zenzaiモデルのシンボリックリンク (`zenzai.gguf`) と、`config.json` / `env` 内の旧ディレクトリを指すパスを、新ディレクトリへ書き換えます。  
- 起動中のHazkey Community-serverはスクリプトがSIGTERMで終了させ、コピー完了後に再度終了を確認します。  
  Fcitx 5 / IBusがキー入力に応じて再起動するため、移行中はHazkey Communityで文字を入力しないでください。  
- 空のディレクトリだけが作成済みの場合は、サーバが自動作成した未使用の雛形とみなしてデータをコピーします。  
  ファイルやシンボリックリンクを含むコピー先はスキップします。  
  
  `--force` を指定すると、既存のコピー先を `<コピー先>.bak-<日時>` へ退避してからコピーします。  
- Fcitx 5の入力メソッド一覧やIBusの入力ソースは書き換えません。  
  移行後、Fcitx 5 / IBusを再起動し、入力メソッド **Hazkey Community** を追加してください。  

<br>

## IBusフロントエンド (実験的)

Fcitx 5と同じhazkey-community-serverを利用する実験的なIBusフロントエンド (`ibus-hazkey-community`) です。  
GitHub Releasesのibus-hazkey-communityパッケージ (`.deb` / `.rpm`) で導入するのが手軽です。(上記「クイックスタート」参照)  

ソースコードからビルドする場合は、CMakeで `-DENABLE_IBUS=ON` オプションを指定します。  
(既定は**OFF**、**pkg-config ibus-1.0**が必要)  

```sh
cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DENABLE_IBUS=ON \
      ..
ninja -j $(nproc)
sudo ninja install
```

インストール後はibus-daemonを再起動し、ibus list-engineに **Hazkey Community** が表示されることを確認してください。  
エンジンは、`${CMAKE_INSTALL_LIBEXECDIR}/ibus-hazkey-community/ibus-engine-hazkey-community`、  
component XMLは、`${CMAKE_INSTALL_DATADIR}/ibus/component/ibus-hazkey-community.xml` に配置されます。  

トランスポートはFcitx 5版と共通 (`hazkey-frontend-common/`) で、候補リフレッシュの間引きポリシーも共通です。  
(`hazkey-frontend-common/candidate_refresh_coalescer.h - hazkey::frontend::CandidateRefreshCoalescer`、30[ms]の立ち上がりエッジ型デバウンス)  

IBus版も連続キー入力時の表示専用リフレッシュを同じポリシーで間引き、タイマのみGLib (`g_timeout_add`) のアダプタで駆動します。  

> 立ち上がりエッジ型デバウンス (リーディングエッジ方式のデバウンス) とは  
> デバウンスとは、短時間に連続して発生するイベントを1回にまとめる (間引く) 手法のことです。  
> 元々は、チャタリングする物理スイッチの信号処理用語で、ソフトウェアではリサイズ・スクロール・キー入力時の連続リフレッシュ抑制等に使われます。  
>  
> 連続キー入力中に候補表示の更新要求が連発しても、先頭の1件はすぐ反映し、30[ms]以内の後続要求は捨てることにより、  
> 入力応答性を落とさず描画負荷だけを抑えている。  

### IBusフロントエンドの既知の制約

- **Fcitx 5とIBusの同時有効化による入力に対応しています。**  
  hazkey-community-serverは、接続ごとに独立した入力セッション (`hazkey-server/Sources/hazkey-server/state.swift - HazkeyServerState`) を持ち、  
  変換エンジン・ユーザ辞書・学習メモリ・Zenzaiモデルは全接続で共有します。  
  (`hazkey-server/Sources/hazkey-server/state.swift - HazkeySharedResources`)  
  
  接続を奪い合いません。  
- **hazkey-community-settingsを起動しても、IME側の入力接続は切断されません。**  
- **同時接続の上限は8です**  
  (`hazkey-server/Sources/hazkey-server/socketManager.swift — SocketManager.maxClientCount`)  
  超過した新規接続は、accept直後にサーバが閉じ、既存セッションは保護されます。  
- **停滞したクライアントが他方を巻き込みません。**  
  ソケットI/Oは期限付きpollで待機 (デフォルトは10秒) するため、  
  (`hazkey-server/Sources/hazkey-server/socketUtils.swift - readData(from:count:timeoutMs:)` / `writeData(to:data:timeoutMs:)`)、  
  応答を返さない/読み取らないクライアントは `hazkey-server/Sources/hazkey-server/socketUtils.swift - SocketError.ioTimeout` で切断され、  
  他のクライアントの処理が再開します。  
- **hazkey-community-settingsで設定を変更しても、他方の入力中テキストは失われません。**  
  設定変更時の再初期化は要求元の接続だけが自分の組成をリセットし、他の接続は組成を保持します。  
  入力テーブルは名前ごとにレジストリへ追加登録されるため (`InputStyleManager.registerInputStyle`)、  
  変更前に挿入済みの要素は旧テーブル名のまま解決できます。  
  
  残差:  
  組成の途中で設定を変更した場合、変更前に入力したキーは旧マッピング、変更後のキーは新マッピングになります。(同一組成内での混在)  
- **残差リスク**:  
  サーバは単一スレッドでリクエストを直列処理するため、片方のZenzai推論中はもう片方の同期RPC応答が遅延し得ます。  
  (クライアントのread timeoutは最大10秒以内、機能的な破綻はありません)  
- **Fcitx 5版の主要な入力操作は、IBus版にも移植済みです。**  
  ライブ変換トグル、文節境界調整 (`Shift+Left` / `Shift+Right`)、予測候補受入、学習データの個別削除、Zenzai トグル、  
  `[F6]`〜`[F10]` と `[Ctrl] + [U]` / `[Ctrl] + [I]` / `[Ctrl] + [O]` / `[Ctrl] + [P]` / `[Ctrl] + [T]` の直接変換、  
  `[Alt]` + 数字での候補選択、生ひらがな + カーソル位置の補助表示 (FcitxのAuxUp / AuxDown) を含みます。  
  無変換キーはFcitx 5版と同様に、組成中に消費されるNOPです。(直接変換は行いません)  
- **パネルの入力モード表示 (IBusProperty) に対応しています。**  
  パネルに「あ」(通常入力) /「A」(直接入力) と、Zenzai の状態を表示します。  
  言語バーの「あ / A」をクリックすると、直接入力をトグルできます。([Shift]キー単体押下と同じRPC経路を利用)  
- **Zenzaiのトグル (ホットキー / パネルのプロパティ) とライブ変換トグル (ホットキー) は、補助テキストに一時的なヒントを約1秒表示します。**  
  IBusにはGNOME Shellを含む全パネルが描画する一時ポップアップAPIが無い ([ibus-rime](https://github.com/rime/ibus-rime) の `status_hint.c` と同じく  
  補助テキストの一時表示で代替。  
  IBus 1.5.33以降の `ibus_engine_send_message()` は、UnstableでGNOME Shell非対応のため採用していません)  
- **候補リストに数字ラベル (1〜9, 0) と縦向き表示を設定しています。**  
- **クライアントのcapability (`set_capabilities`) を反映します。**  
  surrounding text非対応のクライアントでは、surrounding textの取得・送信を行いません。  
  capabilityを申告しないクライアントでは従来どおり動作します。  
- **IBusに固有の未対応項目 (見送り)**:  
  - surrounding textの書き込み経路 (`delete_surrounding_text` / `forward_key_event`) は、サーバ側の新規RPCが必要なため未対応です。  
  - Fcitx 5版の[Tabキーで選択]表示可否設定 (`showTabToSelect`) に相当するIBus側の設定経路はありません。  
    Fcitx 5版の既定値は[表示]であり、IBusは組成中に常時表示するため実質同挙動です。  
- **RPCは非同期化されており、`process_key_event` はサーバ応答でブロックしません。**  
  IBus側の入力状態機械 (`hazkey::ibus::HazkeyState`) は専用ワーカースレッドで逐次実行され、  
  preedit・候補リスト・IBusProperty・補助テキストの更新はGLibメインループへ配送されて適用されます。  
  
  サーバが遅い間もキー入力処理は即座に戻り、応答到着後に表示へ反映されます。  
  既存のread timeout (最大10秒)・response 上限2[MB]・再接続・read-throughキャッシュ無効化・RPC 順序は維持しています。  
  
  応答到着前に次のキーが入力された場合、consume / forwardの判定は直前の確定済み状態に基づくため、稀にサーバレイテンシ分だけ順序がずれることがあります。  
  (未処理と判明したキーは `ibus_engine_forward_key_event` でアプリへ転送されるため、キーが失われることはありません)  
  なお、Fcitx 5フロントエンドは従来どおり同期のままです。  

<br>

## ニューラル変換 (Zenzai / Jinen v2) のセットアップ

Zenzai / jinen-v2のモデル選択・有効化手順・Vulkanドライバの導入・GPU/iGPU要件・モデルの保存場所は、  
[docs/neural-conversion.md](./docs/neural-conversion.md)を参照してください。  

<br>

## 設定・環境のリファレンス

Hazkey Communityが使用するファイルの場所と、サーバ起動時に効く環境変数をここにまとめます。  

### ファイルの場所 (XDGベースディレクトリ準拠)

| 用途 | パス |
|---|---|
| 設定本体 | `$XDG_CONFIG_HOME/hazkey-community/config.json`<br>(通常は `~/.config/hazkey-community/config.json`) |
| 環境変数ファイル | `$XDG_CONFIG_HOME/hazkey-community/env`<br>(通常は `~/.config/hazkey-community/env`) |
| ユーザ辞書 | `$XDG_CONFIG_HOME/hazkey-community/user_dictionary.tsv` |
| Zenzaiモデル | `$XDG_DATA_HOME/hazkey-community/zenzai/`<br>(通常は `~/.local/share/hazkey-community/zenzai/`) |
| 学習データ (入力履歴) | `$XDG_STATE_HOME/hazkey-community/` 配下<br>(通常は `~/.local/state/hazkey-community/`) |
| サーバソケット | `$XDG_RUNTIME_DIR/hazkey-community-server.<uid>.sock` |

### 環境変数ファイル `~/.config/hazkey-community/env`

`hazkey-community-server` の起動時、ラッパースクリプトがこのファイルを `source` してサーバプロセスに引き継ぎます。  
1行1変数の `KEY=value` 形式 (`export` 不要、`#` 以降はコメント)  

ファイルが存在しない場合は何も行われません。  

| 変数名 | 用途 | 設定値 |
|---|---|---|
| `VK_DRIVER_FILES` | 使用するVulkan ICDの明示指定<br>(設定するとhazkey-community-serverはバックエンド安全確認プローブを省略してこの指定をそのまま使用する。マルチGPU環境のSIGILL回避にもなる) | ICDのJSONパス<br>(例: `/usr/share/vulkan/icd.d/nvidia_icd.json`)<br><br>実在名は `ls /usr/share/vulkan/icd.d/` コマンドで確認 |
| `VK_ICD_FILENAMES` | 同上 (Vulkan loader向けの別名)<br>`VK_DRIVER_FILES` と同じ値を書く | 同上 |
| `HAZKEY_ZENZAI_CPU_THREADS` | Zenzai CPU推論のスレッド数 | `1`〜`8`<br>未設定・無効値時は既定動作 |
| `HAZKEY_ZENZAI_DEADLINE_MS` | Zenzai CPU推論1回の上限時間 (ミリ秒) | `0`〜`2000`<br>`0` は期限なし。<br>超過時はニューラル変換なしにフォールバック |
| `HAZKEY_ZENZAI_MODEL` | Zenzai モデルファイル (`zenzai.gguf`) の明示指定 (上級者向け) | 実在する通常ファイルのパス |
| `HAZKEY_DICTIONARY` | 辞書ディレクトリの明示指定 (上級者向け) | 実在するディレクトリのパス |
| `HAZKEY_ADDRESS_DICTIONARY` | 住所辞書 (`AddressDictionary`) ディレクトリの明示指定 (上級者向け)<br>設定するとその値だけを使い、実在するディレクトリでなければ住所辞書を無効にする (システム配備へは切り替えない)<br>未設定時は `/usr/share/hazkey-community/AddressDictionary` を使用 | ディレクトリのパス |
| `HAZKEY_ENGINEERING_DICTIONARY` | 工学用語辞書 (`EngineeringDictionary`) ディレクトリの明示指定 (上級者向け)<br>`HAZKEY_ADDRESS_DICTIONARY` と同じ規則。未設定時は `/usr/share/hazkey-community/EngineeringDictionary` を使用 | ディレクトリのパス |
| `GGML_BACKEND_DIR` | llama.cppバックエンド (`.so`) の探索ディレクトリ (上級者向け) | ディレクトリのパス (末尾 `/` は自動補完) |

**設定例**:  

```sh
mkdir -p ~/.config/hazkey-community
cat > ~/.config/hazkey-community/env <<'EOF'
# NVIDIA GPUのみに固定する例
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
HAZKEY_ZENZAI_CPU_THREADS=4
HAZKEY_ZENZAI_DEADLINE_MS=0
EOF

# 次回サーバ起動時に反映 (即時反映したい場合はサーバを終了)
pkill -u $USER -f '^([^ ]*/)?hazkey-community-server( |$)'
```

> Systemdのドロップイン (`fcitx5.service.d/*.conf` の `Environment=`) でも環境変数は設定できますが、  
> ラッパースクリプトがenvファイルを`source`するため、両方に同じ変数を書いた場合は**`~/.config/hazkey-community/env`側が優先**されます。  
> 混在させずどちらか一方を使用してください。  

<br>

## ソースからのビルド

ソースコードからビルドするための依存関係・Swiftのインストール・ビルド手順・ビルドオプションは、[docs/build.md](./docs/build.md)にまとめています。  

<br>

## トラブルシューティング

既知の問題と対処 (マルチGPU環境でのSIGILLクラッシュ、使用中のフレームワークが新しいバージョンを認識しない、サーバに接続できない等) は、  
[docs/troubleshooting.md](./docs/troubleshooting.md) を参照してください。  

<br>

## 上流・関連プロジェクト

| プロジェクト | 用途 |
|---|---|
| [7ka-Hiira/hazkey](https://github.com/7ka-Hiira/hazkey) | 本プロジェクトの上流<br>ドキュメント: [https://hazkey.hiira.dev/docs](https://hazkey.hiira.dev/docs) |
| [azooKey/AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) | 変換エンジン (本プロジェクトは、forkのhazkeyブランチを使用) |
| [ensan-hcl/azooKey](https://github.com/ensan-hcl/azooKey) | 動詞活用エンジンの移植元 |
| [Miwa-Keita/zenz-v3.2-small-gguf](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf) / [zenz-v3.2-xsmall-gguf](https://huggingface.co/Miwa-Keita/zenz-v3.2-xsmall-gguf) / [zenz-v3.1-small-gguf](https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf) | ニューラル変換モデル (GGUF、zenz系) |
| [togatogah/jinen-v2-small.gguf](https://huggingface.co/togatogah/jinen-v2-small.gguf) / [jinen-v2-xsmall.gguf](https://huggingface.co/togatogah/jinen-v2-xsmall.gguf) | ニューラル変換モデル (GGUF、Qwen3ベース、CC-BY-SA-4.0) |
| [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | Zenzaiの推論バックエンド |
| [fcitx/fcitx5](https://github.com/fcitx/fcitx5) | インプットメソッドフレームワーク (Fcitx 5フロントエンド) |
| [ibus/ibus](https://github.com/ibus/ibus) | インプットメソッドフレームワーク (IBusフロントエンド) |

## ライセンス

[MIT License](./LICENSE)  

本プロジェクトは [7ka-Hiira/hazkey](https://github.com/7ka-Hiira/hazkey) (MIT License) をベースにしています。  
Zenzaiモデルのライセンスは上記のモデル一覧を参照してください。  
