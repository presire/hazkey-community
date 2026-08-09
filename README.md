# fcitx5-hazkey

[![based on 7ka-Hiira/hazkey](https://img.shields.io/badge/based%20on-7ka--Hiira%2Fhazkey-blue)](https://github.com/7ka-Hiira/hazkey)  

> このプロジェクトは [7ka-Hiira/hazkey](https://github.com/7ka-Hiira/hazkey) をベースにしたカスタマイズ版です。(v0.2.2-community以降)  
> ユーザ辞書 (品詞・動詞活用対応)・動詞活用エンジン、ライブ変換トグルホットキー、文節境界調整・自動変換の改善、設定UI強化 (辞書タブ・動詞活用情報表示)、  
> サーバプロセス管理の安定化、マルチGPU環境でのSIGILLクラッシュ回避 ([Issue #29](https://github.com/7ka-Hiira/hazkey/issues/29)) 等の追加機能を含みます。  

Hazkey input method for fcitx5  

[AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)を利用したIMEです。  

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
- Vulkan SDK ヘッダ (`libvulkan-dev` / `vulkan-headers`) - GGML_VULKAN=ON (デフォルト) のビルドで必要

### ソースビルド・インストール手順

ninjaを利用します。  

```sh
git clone --recursive https://github.com/7ka-Hiira/hazkey.git
cd hazkey
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -G Ninja ..
ninja
sudo ninja install
```

### ビルドオプション

| オプション | デフォルト | 説明 |
|---|---|---|
| `GGML_VULKAN` | `ON` | Zenzai ニューラル変換の Vulkan バックエンド。GPU アクセラレーションを使用しない場合は `-DGGML_VULKAN=OFF` で CPU 専用ビルドになります |

CPU 専用ビルドの例:  

```sh
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DGGML_VULKAN=OFF -G Ninja ..
```

## トラブルシューティング

### マルチGPU環境でhazkey-serverがSIGILLでクラッシュする

NVIDIA GPUとAMD/Intel iGPUが同居するLinux環境 (両方のVulkan ICDがインストール済み) で、  
`hazkey-server` が起動直後にSIGILL (signal 4) でクラッシュする現象があります。  
上流Issue [#29](https://github.com/7ka-Hiira/hazkey/issues/29) を参照してください。  

**原因**:  
Zenzai初期化時に `ggml_backend_load_all()` → Vulkan loaderがシステム内の全 ICD (`nvidia_icd.json`, `radeon_icd.json` 等) をロードし、  
ベンダー混在の競合状態でSwift runtimeのprecondition failure (`ud2` → SIGILL) が発火します。  

SIGILLはtrap命令のため `do/catch` で捕捉できません。  

**回避策**:  
本プロジェクトでは以下の3層で自動的に回避します。  

1. **ラッパースクリプト** (`hazkey-server.sh`):  
   `VK_DRIVER_FILES` / `VK_ICD_FILENAMES` が未設定の場合、  
   検出したICDのうち最初の1つだけを `export` してからhazkey-serverを起動します。  
2. **Zenzai 側** (`AzooKeyKanaKanjiConverter` fork):  
   `ZenzContext.createContext` が `ggml_backend_load_all()` を呼ぶ前に、  
   ICDを1つに絞るロジックをビルド時にパッチとして自動適用します。(`hazkey-server/patches/0001-zenzai-pin-vulkan-icd.patch`)
3. **CPU フォールバック**:  
   Vulkanを完全に無効化したい場合は `-DGGML_VULKAN=OFF` でCPU専用ビルドが可能です。  

**ユーザーによる明示的な指定** (最も優先されます):  

```sh
# 例: NVIDIA のみに固定
mkdir -p ~/.config/hazkey
cat > ~/.config/hazkey/env <<'EOF'
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
EOF
```

```sh
# 例: AMD のみに固定
mkdir -p ~/.config/hazkey
cat > ~/.config/hazkey/env <<'EOF'
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json
EOF
```

> 注:  
> AMDのICDファイル名はディストリビューション・ドライバにより異なります。  
> Mesa (RADV) は `radeon_icd.json`、AMD公式ドライバ (amdvlk) は `amd_icd.x86_64.json` が主な候補です。  
> 実際のファイル名は `ls /usr/share/vulkan/icd.d/` で確認してください。  

<u>`~/.config/hazkey/env` に書いた環境変数は、hazkey-server起動時に読み込まれ、自動判定を上書きします。</u>  
<u>Systemdサービスユニットのdrop-inで設定することも可能です。  

## ライセンス

[MIT License](./LICENSE)  
