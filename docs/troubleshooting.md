# トラブルシューティング

## マルチGPU環境でhazkey-community-serverがSIGILLでクラッシュする

NVIDIA GPUとAMD/Intel iGPUが同居する環境 (両方のVulkan ICDがインストール済み) で、`hazkey-community-server` が起動直後にSIGILL (signal 4)でクラッシュする現象があります。  
([上流 Issue #29](https://github.com/7ka-Hiira/hazkey/issues/29))  

**原因**:  
Zenzai初期化時にVulkan loaderがシステム内の全ICDをロードし、ベンダー混在の競合状態でSwiftランタイムのprecondition failure (`ud2` 命令、SIGILL) が発生します。  
SIGILLはtrap命令のため `do/catch` で捕捉できません。  

**コミュニティ版の自動回避 (隔離プローブ方式)**:  

`hazkey-community-server` は起動のたびに、GPUバックエンド (Vulkan) のロードをまず**隔離した子プロセス** (自分自身を `--probe-backends` で再実行) で試します。  
この子プロセスがクラッシュ・タイムアウト (既定5秒)・異常終了した場合、実サーバ本体を巻き込まずに危険なドライバ組み合わせを検出し、  
そのセッションはVulkanを含まないバックエンドディレクトリから読み込み直して**CPU専用のニューラル変換に自動フォールバック**します。  

GPUアクセラレーションが無言で無効化されないよう、フォールバックが発生した場合は設定UI ([AI]タブ) に警告バナーが表示され、  
`~/.config/hazkey-community/env` で単一ICDを固定してから使用中のフレームワークを再起動するよう案内します。  

`VK_DRIVER_FILES` / `VK_ICD_FILENAMES` / `VK_ADD_DRIVER_FILES` / `VK_LOADER_DRIVERS_SELECT` / `VK_LOADER_DRIVERS_DISABLE` のいずれかが設定されている場合、  
その明示指定を信頼してこの安全確認プローブ自体を省略します (ユーザの明示指定が常に最優先されます)。  

> **旧方式との違い**:  
> 以前は、`hazkey-server.sh` (ラッパースクリプト) が、`VK_DRIVER_FILES` / `VK_ICD_FILENAMES` 未設定時に  
> 「最初に検出したベンダーのICDへ固定する」ヒューリスティックを実装していましたが、  
> 最初に列挙されたマニフェストが未認識ドライバやアーキテクチャ不一致のドライバだった場合、動作するGPUが無言で不可視になる問題がありました。([Issue #2](https://github.com/presire/hazkey-community/issues/2))  
> 現在のラッパースクリプトはVulkan ICDの選択に一切関与せず、Vulkan Loaderの標準探索にそのまま委ねます。  
> (Vulkan Loader >= 1.3.219 とMesa >= 25.2.1 の組み合わせでは、loaderがアーキテクチャ不一致のマニフェストを自動的に除外)  
> マルチベンダー構成のクラッシュ対策は、上記の隔離バックエンドプローブに一本化されています。  

それでも症状が出る・特定のGPUに固定したい場合は、`~/.config/hazkey-community/env`ファイルで`VK_DRIVER_FILES` / `VK_ICD_FILENAMES`を設定してください。  
(書式・設定例は[設定・環境のリファレンス](../README.md#設定・環境のリファレンス) 参照)  

Vulkanを完全に無効化したい場合は、`-DGGML_VULKAN=OFF` の [CPU専用ビルド](./build.md#ビルドオプション) も可能です。  

ICDのファイル名はドライバにより異なります。  
(NVIDIA: `nvidia_icd.json`、AMD Mesa: `radeon_icd.json`、AMD 公式: `amd_icd.x86_64.json`、Intel Mesa: `intel_icd.x86_64.json` 等)  

実際のファイル名は `ls /usr/share/vulkan/icd.d/` コマンドで確認してください。  

## Fcitx 5が新しいバージョンを認識しない

```sh
fcitx5-remote -r                          # 設定リロード
rm -rf ~/.cache/fcitx5/hazkey-community/  # キャッシュクリア
systemctl --user restart fcitx5.service   # 完全再起動
```

学習データは、`~/.local/state/hazkey-community/`ディレクトリ内に保持されるため失われません。  

## XIMを使用するアプリケーションで読みと変換結果が重複表示される

X11環境でXIMを使うアプリに入力した時、入力中の読みと変換結果が同じ行に連結されて表示される場合があります。  
これは、Fcitx 5のXIMフロントエンドでOn The Spotスタイルが無効になり、入力パネル側の表示にフォールバックしている時に発生します。  

**対処方法**:  

1. Fcitx 5の設定ツール (`fcitx5-configtool`) またはデスクトップ環境の入力メソッド設定を開きます。  
2. [X Input Method フロントエンド]の設定で、[XIMでOn The Spotスタイルを使う]チェックボックスを有効にします。  
3. 設定ファイルで指定する場合は、次のように記述します。  

   ```ini
   # ~/.config/fcitx5/conf/xim.conf
   
   UseOnTheSpot=True
   ```

   `XDG_CONFIG_HOME`を設定している場合は、`$XDG_CONFIG_HOME/fcitx5/conf/xim.conf`を使用します。  
   `[General]`などのセクションを付けると、Fcitx 5では設定が読み込まれません。  
4. Fcitx 5を完全に再起動し、対象アプリケーションも再起動します。  
   
   ```sh
   fcitx5 -r
   # または
   systemctl --user restart fcitx5.service
   ```
   
   `fcitx5-remote -r`だけでは、既存のXIMサーバに設定が反映されない場合があります。  

## IBusが新しいバージョンを認識しない

```sh
ibus restart                              # デーモン再起動
ibus list-engine | grep hazkey-community  # Hazkey-Community が出なければ component 登録を確認
```

component XML (`${CMAKE_INSTALL_DATADIR}/ibus/component/ibus-hazkey-community.xml`) が配置されているかも確認してください。  

## サーバに接続できない

```sh
pgrep -af hazkey-community-server                    # 起動確認
ls -la "$XDG_RUNTIME_DIR"/hazkey-community-server.*.sock  # ソケット確認
```

サーバプロセスが終わっている場合は、使用中のフレームワーク (Fcitx 5 / IBusデーモン) を再起動すると再度起動します。  
手動起動での切り分けは、インストール先の `hazkey-community-server` (ラッパースクリプト) を実行して確認できます。  

## ユーザ辞書が反映されない

- `~/.config/hazkey-community/user_dictionary.tsv`の書式 (`読み<TAB>単語<TAB>コメント[<TAB>品詞]`) を確認してください。  
- サーバはファイルの更新日時を監視して自動再読込しますが、反映されない場合は `pkill -u $USER -f '^([^ ]*/)?hazkey-community-server( |$)'` コマンドを実行してサーバを再起動してください。  

## ZenzaiのGPUデバイスが選択肢に出ない

- `vulkaninfo --summary` コマンドでGPUが列挙されるか確認してください。  
- Vulkan ドライバ導入後は、使用中のフレームワーク (およびサーバ) の再起動が必要です。  
- CPUでもZenzaiは使用可能です。  
  バックエンドデバイスに「CPU」を選択してください。  
