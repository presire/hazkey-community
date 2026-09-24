# ニューラル変換 (Zenzai / Jinen v2) のセットアップ

Zenzaiは、llama.cppをバックエンドとするオプションのニューラル変換機能です。  
**GPU (Vulkan) がなくてもCPUだけで使用できます**。  

設定UI ([AI]タブ) では、zenz系・jinen系等モデルの種類に依存しない表記として**「ニューラル変換」**を使用しています。  

> タブ見出し・有効化チェックボックス・カスタム重み・トグルホットキー・モデル管理ダイアログ等  
> protobufのフィールド名やウィジェットのオブジェクト名、ファイル名・環境変数名は引き続き `zenzai` を使用します。  

ローエンドGPUよりCPUの方が速い・安定な場合もあるため、必ずしもGPUが必要ではありません。  

## モデルの選択

Zenzaiモデルは、設定UIの[AI]タブにある[ニューラル変換モデルの管理]からダウンロード・有効化・削除できます。  
ダウンロード時は、受信バイト数とSHA-256の両方が照合されます。転送が30秒間停止した場合はタイムアウトし、再試行またはキャンセルを選べます。  

現在提供されているモデルは以下の通りです。  

| モデル | サイズ | 特徴 | ライセンス |
|---|---|---|---|
| **zenz-v3.2-small** | 約 74 [MB] | 推奨<br>最新世代の標準モデル | Apache-2.0 |
| **zenz-v3.2-xsmall** | 約 21 [MB] | 軽量<br>CPUで高速、精度はやや低め | Apache-2.0 |
| zenz-v3.1-small | 約 74 [MB] | 旧世代<br>既存環境との互換維持用 | CC-BY-SA-4.0 |
| jinen-v2-small | 約 69〜210 [MB]<br>(量子化により変動) | 実験的<br>Qwen3ベース<br>量子化を選択可能 | CC-BY-SA-4.0 |
| jinen-v2-xsmall | 約 25〜69 [MB]<br>(量子化により変動) | 実験的<br>Qwen3ベース<br>量子化を選択可能 | CC-BY-SA-4.0 |

新規利用は **zenz-v3.2-small** を推奨します。  
CPU中心で使う・軽量重視の場合は **zenz-v3.2-xsmall** が適しています。  

v3.1はv3.2の後継に置き換えられているため、既存環境の再現用途以外での新規利用は推奨しません。  

### karukan jinen-v2 (実験的: Qwen3ベース)

jinen-v2は、[togatogah](https://huggingface.co/togatogah) 氏が公開する **Qwen3** ベースの日本語変換モデルで、[CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/) のもとで配布されています。  
[ニューラル変換モデルの管理] では系列ごとに量子化 (`f16` / `Q8_0` / `Q5_K_M` / `Q4_K_M`) を選択でき、選択したアーティファクトだけがダウンロードされます。  

| 系列 | 配布リポジトリ | 量子化 | サイズ |
|---|---|---|---|
| jinen-v2-small | [togatogah/jinen-v2-small.gguf](https://huggingface.co/togatogah/jinen-v2-small.gguf) | `f16`<br>`Q8_0`<br>`Q5_K_M`<br>`Q4_K_M` | 約 69〜210 [MB] |
| jinen-v2-xsmall | [togatogah/jinen-v2-xsmall.gguf](https://huggingface.co/togatogah/jinen-v2-xsmall.gguf) | `f16`<br>`Q8_0`<br>`Q5_K_M`<br>`Q4_K_M` | 約 25〜69 [MB] |

- **帰属**:  
  本モデルは、togatogah氏の成果物です。(ライセンスは、CC-BY-SA-4.0)  
  設定画面の[ニューラル変換モデルの管理]にも、著作者・ライセンス・配布元へのリンクを表示します。  
- **重みは非同梱**:  
  モデルの重みはHazkey-Communityのソース、インストール先、DEB/RPMパッケージ、ソースアーカイブのいずれにも同梱されません。  
  上記の配布元から、利用者が明示的にダウンロードした場合のみ取得されます。  
- **完全性検証**:  
  ダウンロードしたGGUFは、固定カタログに記録した期待バイト数とSHA-256の両方に照合され、一致したアーティファクトだけが選択・削除の対象になります。  
- **Qwen3 前提**:  
  jinen-v2はQwen3アーキテクチャのため、  
  コンバータ依存 (`presire/AzooKeyKanaKanjiConverter`の`hazkey`ブランチ) に Qwen3 対応が焼き込み済みである必要があります。(`Package.resolved`が指すリビジョン以降)  
  この対応は、GGUFの`general.architecture == "qwen3"`を検出した場合にのみ、NFKC正規化・BOS付与の無効化・条件トークン類の抑止を有効化し、  
  既存のzenz (GPT-2系) の前処理・BOS・条件トークンの動作は変更しません。  
- **トークナイザ**:  
  追加の`tokenizer.json`は不要です。(llama.cpp内蔵トークナイザのみを使用します)  
- **zenzの既定は不変**:  
  推奨モデルは従来通り、**zenz-v3.2-small**で、zenz側のラベル・推奨表示・既定の有効化状態・旧世代警告 (`zenz-v3.1-small`) は変更ありません。  
  jinen-v2は推奨にも既定にもせず、旧世代扱いもしません。  
- **条件付けフィールドは自動的に無効化**:  
  jinen-v2はプロファイル・トピック・文体・好み (条件トークン: U+EE03〜EE06) に対応していません。  
  jinen系モデルが有効な間は、設定UIの該当4項目とラベルが自動的にグレーアウトされ、ツールチップで理由 (「有効なモデルでは対応していません。」) を表示します。  
  カスタム重み指定時はファイル名からjinenモデルかどうかを推定し、判別できない場合は既定で有効のままにします。  

jinen-v2は実験的な位置づけであり、新規利用の第一候補は**zenz-v3.2-small**です。  

## 有効化の手順

1. `hazkey-community-settings` を起動し、[AI]タブを開きます。  
2. [ニューラル変換モデルの管理]から利用したいモデルをダウンロードします。  
3. [ニューラル変換を有効化]にチェックを入れ、バックエンドデバイス (CPUまたはVulkan GPU) を選択して、[適用]または[OK]を押します。  
   有効化には数十秒かかる場合があり、進行中は待機ダイアログが表示されます。反映後はサーバが起動時 (設定リロード時) にモデルを事前ウォームアップするため、  
   切替直後の初回変換が極端に遅くなることはありません。  
4. GPUバックエンドの選択肢に表示されない場合は、Vulkanドライバの導入状態を確認した上で、使用中のフレームワークを再起動します。
   (Fcitx 5: `systemctl --user restart fcitx5.service`、IBus: `ibus restart`)

Vulkanを使ったGPU変換には、各ディストリビューションのVulkanドライバ (NVIDIA公式ドライバ、MesaのRADV/ANV等) が必要です。  
`vulkaninfo --summary` (パッケージ `vulkan-tools`) でGPUが列挙されれば利用可能です。  

### Vulkanドライバのインストール例

使用するGPUとディストリビューションに応じて、以下を参考にインストールしてください。  
`vulkan-tools`は、デバイスの確認に使用する`vulkaninfo`コマンドを含みます。  

**openSUSE Leap 16**  

```sh
# Intel GPU/iGPU
sudo zypper install libvulkan_intel vulkan-tools

# AMD GPU/iGPU
sudo zypper install libvulkan_radeon vulkan-tools

# NVIDIA GPU (NVIDIAリポジトリの登録と再起動が必要)
sudo zypper addrepo https://download.nvidia.com/opensuse/leap/16.0/ nvidia
sudo zypper --gpg-auto-import-keys refresh
sudo zypper install nvidia-open-driver-G06-signed-kmp-default nvidia-video-G06 nvidia-gl-G06 vulkan-tools
```

**Fedora 44**  

```sh
# Intel GPU/iGPU / AMD GPU/iGPU (Mesa ANV / RADV)
sudo dnf install mesa-vulkan-drivers vulkan-tools

# NVIDIA GPU (RPM Fusionの登録と再起動が必要)
sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
                 https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf install akmod-nvidia vulkan-tools
```

**Debian 13 (Trixie)**  

```sh
# Intel GPU/iGPU / AMD GPU/iGPU (Mesa ANV / RADV)
sudo apt install mesa-vulkan-drivers vulkan-tools

# NVIDIA GPU (non-freeコンポーネントの有効化と再起動が必要)
sudo apt install nvidia-kernel-dkms nvidia-driver nvidia-vulkan-icd vulkan-tools
```

NVIDIAドライバは、GPU世代によって必要なパッケージや対応状況が異なります。  
詳細は各ディストリビューションのドキュメントを参照してください。  
([openSUSE](https://en.opensuse.org/SDB:NVIDIA_drivers)、[Fedora](https://rpmfusion.org/Howto/NVIDIA)、[Debian](https://wiki.debian.org/NvidiaGraphicsDrivers))  

## GPU / iGPUの最低要件と性能の目安

GPU/iGPUを使用するための最低ラインは、Vulkan 1.2以上に対応し、システムとHazkey-Communityから認識できることです。  

### 動作上の最低条件

GPU/iGPUでZenzaiを使用する場合、次の条件をすべて満たす必要があります。  

- Vulkan 1.2以上に対応したGPUまたはiGPUと、対応するVulkanドライバがインストールされていること  
- hazkey-community-serverが `GGML_VULKAN=ON` でビルドされていること  
- `vulkaninfo --summary` で対象デバイスが列挙されること  
- フレームワーク再起動後、`hazkey-community-settings` の[AI]タブで対象デバイスがVulkanバックエンドとして表示され、選択できること  

これらはVulkanバックエンドを利用できるかの確認条件であり、変換速度や安定性を保証するものではありません。  

### 一般的なVulkan対応例

以下は、Vulkan 1.2以上に対応する構成の代表例です。  
***hazkey-communityでZenzaiの動作を確認・認定した機種一覧ではなく、最低要件や推奨機種を示すものでもありません。***  

| 区分 | 型番・製品系列の例 |
|---|---|
| NVIDIA GeForce (dGPU) | GeForce GTX 1050<br>GTX 1650<br>GTX 1660 SUPER<br>RTX 3060<br>RTX 4060 |
| AMD Radeon (dGPU) | Radeon RX 560<br>RX 6400<br>RX 6600<br>RX 7600 |
| Intel iGPU | Intel UHD Graphics 630<br>UHD Graphics 730<br>UHD Graphics 770<br>Iris Xe Graphics |
| AMD iGPU | Radeon Vega 8<br>Radeon 680M<br>Radeon 760M<br>Radeon 780M |

Vulkan対応状況の確認には、[NVIDIA Vulkan Driver Support](https://developer.nvidia.com/vulkan-driver)、[Mesa RADV](https://docs.mesa3d.org/drivers/radv.html)、[Intel Supported APIs](https://www.intel.com/content/www/us/en/support/articles/000005524/graphics.html)、[Khronosの適合製品一覧](https://www.khronos.org/conformance/adopters/conformant-products)を参照してください。  

同じ型番でも、OS、Vulkanドライバの種類とバージョン、デスクトップ版・モバイル版・OEM版によって結果が異なります。  
llama.cppの実行時のデバイス機能検査により、Vulkan 1.2対応のデバイスでも利用できない場合があります。  

上記はVulkan API対応の目安であり、Hazkey-Communityでの変換速度や安定性を示すものではありません。  
iGPUはシステムメモリを共有するため、専用VRAMのGPUとは利用可能なメモリ容量や帯域が異なります。  

### 性能について

本リポジトリでは、特定のGPU型番・世代、GPU/iGPUの最低性能、VRAM容量、最低処理速度を定めていません。  
モデルファイルのサイズ（約 21 [MB] / 約 74 [MB]）は、実行時に必要なVRAM容量を示すものではありません。  

GPU/iGPUの性能、専用メモリまたは共有メモリの空き容量、Vulkanドライバ、CPU、システムの負荷によって、変換速度や安定性は変わります。  
ローエンドのGPU/iGPUではCPUより遅くなる場合もあるため、実際の環境でCPUバックエンドとVulkanバックエンドを比較し、  
より速く安定して動作するバックエンドを選択してください。  

GPU/iGPUが条件を満たさない場合や、GPU/iGPUよりCPUの方が適している場合でも、CPUバックエンドでZenzaiを使用できます。  

## モデルの保存場所とアクティブモデル

- ダウンロードしたモデル本体:  
  `~/.local/share/hazkey-community/zenzai/models/<モデルキー名>.gguf`  
- アクティブなモデル:  
  `~/.local/share/hazkey-community/zenzai/zenzai.gguf`  
  (上記models配下へのシンボリックリンク。[ニューラル変換モデルの管理]のアクティブ化 / 無効化でこのリンクが切り替わります)  
- サーバは、環境変数`HAZKEY_ZENZAI_MODEL` (任意) > ユーザディレクトリのzenzai.gguf > システム配備のモデルの順に探索します。  
