# fcitx5-hazkey

[![based on 7ka-Hiira/hazkey](https://img.shields.io/badge/based%20on-7ka--Hiira%2Fhazkey-blue)](https://github.com/7ka-Hiira/hazkey)  

> このプロジェクトは [7ka-Hiira/hazkey](https://github.com/7ka-Hiira/hazkey) をベースにしたカスタマイズ版です。(v0.2.2-community以降)  
> ユーザ辞書 (品詞・動詞活用対応)・動詞活用エンジン、ライブ変換トグルホットキー、文節境界調整・自動変換の改善、設定UI強化 (辞書タブ・動詞活用情報表示)、  
> サーバプロセス管理の安定化、マルチGPU環境でのSIGILLクラッシュ回避 ([Issue #29](https://github.com/7ka-Hiira/hazkey/issues/29)) 等の追加機能を含みます。  

Hazkey input method for fcitx5  

[AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)を利用したIMEです。  

<br>

## コミュニティ版の追加機能 (v0.2.2-community以降)

本カスタマイズ版では、上流 ([7ka-Hiira/hazkey](https://github.com/7ka-Hiira/hazkey)) の `v0.2.2-community` 以降において、以下の機能追加・改善を行っています。  

### ユーザ辞書 (品詞・動詞活用対応)

TSV形式 (`読み<TAB>単語<TAB>コメント[<TAB>品詞]`) で単語を登録できる軽量なユーザ辞書です。  
品詞 (固有名詞・人名・地名・動詞) を指定すると、AzooKeyKanaKanjiConverterの接続コスト評価に正しく参加するようになり、  
候補ランキングに品詞が反映されます。  

従来は、単純な前方挿入でエンジンのラティスをバイパスしていたため、品詞がランキングに影響しませんでした。  
既存の3列TSVファイルも後方互換性を保ち読み込めます。  

### 動詞活用エンジン (azooKey由来)

azooKeyの `JapaneseConjugationBuilder` を移植した動詞活用エンジンです。  
ユーザ辞書に登録した動詞エントリから全活用形を自動生成し、それぞれに正しいCIDを割り当てて接続コスト評価を適切に行います。  

五段活用 (か・が・さ・た・な・ば・ま・ら・わ行)・一段活用・サ行変格 (する) に対応しています。  

### 文節境界調整 (Shift+Left / Shift+Right)

変換中に `Shift+Left` / `Shift+Right` で文節の境界を直接調整できるようになりました。  
エンジンが判定した文節区切りをユーザ側で微調整できるため、複雑な文でも意図通りに変換しやすくなります。  

### 自動変換の最小文字数を設定可能に

ライブ変換 (自動変換) がトリガーされるまでの最小文字数を設定UIから変更可能になりました。  
入力中の空の未確定文字列 (preedit) 更新による入力消失も回避されるよう改善されています。  

### ライブ変換トグルホットキー

`Ctrl+Shift+L` (デフォルト、設定で変更可能) でライブ変換のON / OFFを即座に切り替えられます。  

トグルはサーバ側の `auto_convert_mode` を同期的に切り替え (約3〜5msで体感不可)、  
OFF時のモードは記憶されてアプリ間のコンテキスト切替をまたいで維持されます。  

### 設定UI強化 (辞書タブ・動詞活用情報表示)

ユーザ辞書の追加・編集・削除・TSV形式でのインポート・エクスポート、プロファイルごとの有効 / 無効切替を辞書タブに集約しました。  
単語編集ダイアログで「動詞」を選ぶと、読みの語尾から活用形が自動生成されることがUI上に表示されます。  

### サーバプロセス管理の安定化

クライアント (fcitx5-hazkey) 更新時にhazkey-serverを自動再起動する仕組みを追加し、  
プロセス起動検出・再起動ハンドリング・学習データ保存の信頼性を向上させました。  

これによりバージョンアップ時の再起動トラブルが軽減されています。  

### マルチGPU環境でのSIGILLクラッシュ回避 ([Issue #29](https://github.com/7ka-Hiira/hazkey/issues/29))

NVIDIA GPUとAMD/Intel iGPUが同居するLinux環境において、hazkey-serverが起動直後にSIGILLでクラッシュする問題を、  
ラッパースクリプトによるICDピン留め・Zenzaiビルド時パッチ・CPUフォールバック (`-DGGML_VULKAN=OFF`) の3層で自動回避します。  

詳細は下記「トラブルシューティング」セクションを参照してください。  

<br>

## ホームページ

[https://hazkey.hiira.dev](https://hazkey.hiira.dev)  

## ドキュメント

[https://hazkey.hiira.dev/docs](https://hazkey.hiira.dev/docs)  

## インストール

[インストールガイド](https://hazkey.hiira.dev/docs/install)  

現在AURと[debianパッケージ](https://github.com/7ka-Hiira/fcitx5-hazkey/releases/latest)が利用できます。  

## ビルド

詳細は[ドキュメントのビルドページを参照してください](https://hazkey.hiira.dev/docs/development/build)。  

### 依存関係

- Swift >= 6.1
- fcitx5 >= 5.0.4
- Qt >= 6.7 (6.2以降でビルド可能ですが表示が崩れる場合があります)
- CMake >= 3.21 (4.x以降推奨)
- Protobuf >= 3.12
- Ninja
- Gettext
- Vulkan SDKヘッダ (`libvulkan-dev` / `vulkan-headers`) - `GGML_VULKAN=ON` (デフォルト) のビルドで必要

### ソースビルド・インストール手順

ninjaを利用します。  

```sh
git clone --recursive https://github.com/presire/hazkey-community
cd hazkey-community

mkdir build && cd build

cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release  \
      -DCMAKE_INSTALL_PREFIX=/usr \
      ..
ninja
sudo ninja install
```

### ビルドオプション

| オプション | デフォルト | 説明 |
|---|---|---|
| `GGML_VULKAN` | `ON` | Zenzaiニューラル変換のVulkanバックエンド<br>GPUアクセラレーションを使用しない場合は、`-DGGML_VULKAN=OFF` でCPU専用ビルドになります。 |

CPU専用ビルドの例:  

```sh
git clone --recursive https://github.com/presire/hazkey-community
cd hazkey-community

mkdir build && cd build

cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release  \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DGGML_VULKAN=OFF \
      ..
ninja
sudo ninja install
```

## トラブルシューティング

### マルチGPU環境でhazkey-serverがSIGILLでクラッシュする

NVIDIA GPUとAMD/Intel iGPUが同居するLinux環境 (両方のVulkan ICDがインストール済み) で、  
`hazkey-server` が起動直後にSIGILL (signal 4) でクラッシュする現象があります。  
上流Issue [#29](https://github.com/7ka-Hiira/hazkey/issues/29) を参照してください。  

**原因**:  
Zenzai初期化時に `ggml_backend_load_all()` → Vulkan loaderがシステム内の全ICD (`nvidia_icd.json`, `radeon_icd.json` 等) をロードして、  
ベンダー混在の競合状態でSwiftランタイムのprecondition failure (`ud2` → SIGILL) が発生します。  

SIGILLはtrap命令のため `do/catch` で捕捉できません。  

**回避策**:  
本プロジェクトでは、以下の3層で自動的に回避します。  

1. **ラッパースクリプト** (`hazkey-server.sh`):  
   `VK_DRIVER_FILES` / `VK_ICD_FILENAMES` が未設定の場合、  
   検出したICDのうち最初の1つだけを `export` してからhazkey-serverを起動します。  
2. **Zenzai側** (`AzooKeyKanaKanjiConverter` fork):  
   `ZenzContext.createContext` が `ggml_backend_load_all()` を呼ぶ前に、  
   ICDを1つに絞るロジックをビルド時にパッチとして自動適用します。  
   (`hazkey-server/patches/0001-zenzai-pin-vulkan-icd.patch`)
3. **CPUフォールバック**:  
   Vulkanを完全に無効化したい場合は `-DGGML_VULKAN=OFF` でCPU専用ビルドが可能です。  

**ユーザによる明示的な指定** (最も優先されます):  

```sh
# 例: NVIDIA GPUのみに固定
mkdir -p ~/.config/hazkey
cat > ~/.config/hazkey/env <<'EOF'
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
EOF
```

```sh
# 例: AMD GPUのみに固定
mkdir -p ~/.config/hazkey
cat > ~/.config/hazkey/env <<'EOF'
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json
EOF
```

```sh
# 例: Intel iGPUのみに固定
mkdir -p ~/.config/hazkey
cat > ~/.config/hazkey/env <<'EOF'
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/intel_icd.x86_64.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/intel_icd.x86_64.json
EOF
```

> 注:  
> ICDファイル名はディストリビューション・ドライバにより異なります。  
> - **AMD**: Mesa (RADV) は `radeon_icd.json`、AMD公式ドライバ (amdvlk) は `amd_icd.x86_64.json`  
> - **Intel**: Mesa (ANV) は `intel_icd.x86_64.json` (32ビット環境では `intel_icd.i686.json`)  
>
> 実際のファイル名は、`ls /usr/share/vulkan/icd.d/` コマンドで確認してください。  

<u>`~/.config/hazkey/env` に書いた環境変数は、hazkey-server起動時に読み込まれ、自動判定を上書きします。</u>  

#### Systemdサービスユニットのドロップインによる設定

hazkey-serverはfcitx5がオンデマンドで起動する子プロセスとして動作するため、  
fcitx5ユーザサービス (`/usr/lib/systemd/user/fcitx5.service`) に環境変数を設定すると、  
子プロセスのhazkey-serverにも継承されます。  

ラッパースクリプトは既存の環境変数を優先するため、ドロップインでの指定も確実に効きます。  

> **`~/.config/hazkey/env` との優先関係**:  
> ラッパースクリプトは `~/.config/hazkey/env` を `source` するため、  
> 両方に異なる値を書いた場合は **`~/.config/hazkey/env` 側が優先**されます。  
> そのため、混在させず、どちらか一方を使用してください。  

**ドロップインファイルの作成**:  

```sh
mkdir -p ~/.config/systemd/user/fcitx5.service.d
```

```ini
# ~/.config/systemd/user/fcitx5.service.d/vulkan-icd.conf
# 例: NVIDIA GPUのみに固定

[Service]
Environment="VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json"
Environment="VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json"
```

他のGPU向けは `Environment=` の値を以下に差し替えてください:  

| GPU | 設定値 |
|---|---|
| AMD (Mesa RADV) | `/usr/share/vulkan/icd.d/radeon_icd.json` |
| AMD (amdvlk) | `/usr/share/vulkan/icd.d/amd_icd.x86_64.json` |
| Intel (Mesa ANV) | `/usr/share/vulkan/icd.d/intel_icd.x86_64.json` |

**反映と確認**:  

```sh
systemctl --user daemon-reload
systemctl --user restart fcitx5.service

# 適用されている環境変数を確認
systemctl --user show fcitx5.service | grep ^Environment
# fcitx5プロセスが実際に持っている環境変数 (hazkey-serverも継承)
cat /proc/$(pgrep -x fcitx5)/environ | tr '\0' '\n' | grep VK_
```

## ライセンス

[MIT License](./LICENSE)  
