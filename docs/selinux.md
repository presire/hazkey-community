# SELinuxポリシー (任意)

> Hazkey Community専用のSELinuxポリシーモジュールの概要と導入方法です。  

SELinuxが有効な環境で、Hazkey Communityを`/usr`以外 (`/usr/local`、`/opt`、ホームディレクトリ等) にインストールすると、  
ファイルにはインストール先の既定のラベルが付きます。  
このため、SELinuxの拒否 (AVC) が記録されたり、変換サーバが起動できなかったりする場合があります。  

この問題を避けるために、Hazkey Community専用のSELinuxポリシーモジュールを同梱しています。  

- 全てのインストール先に対して、一貫したファイルラベルを付けます。  
- 変換サーバ (`hazkey-community-server`) を専用のドメインで動作させます。  
  変換サーバは全てのキー入力を受け取るため、TCP通信とポートでの待ち受けは許可しません。  
- GPU (Vulkan) の使用、ホームディレクトリ配下のモデルの読み取り、GPUドライバのキャッシュへの書き込みは、Booleanで個別に無効にできます。  

`/usr`にRPMパッケージまたはDEBパッケージでインストールした場合は、`/usr`の標準のラベルで動作するため、通常は不要です。  

<br>

## 対象と動作確認

| 項目 | 内容 |
|---|---|
| 対象のドメイン | 変換サーバのみ<br>Fcitx 5のアドオン、IBusのエンジン、設定GUIは、起動元のドメインのまま動作する |
| 許可の範囲 | unconfined_t、user_t、staff_tからの起動とソケット接続 |

<br>

## 必要なパッケージ

| ディストリビューション | パッケージ |
|---|---|
| Fedora、openSUSE | selinux-policy-devel、checkpolicy、policycoreutils、policycoreutils-python-utils |
| Debian 13、Ubuntu 26.04 | selinux-policy-default、checkpolicy、policycoreutils、semodule-utils、selinux-utils、make |

Debian 13とUbuntu 26.04は、基本ポリシーの型名がFedoraやopenSUSEと異なります。  
ビルド時に、型名を自動で置き換えます。  

<br>

## ビルドとインストール

ポリシーモジュールは、既定ではビルドされません。  
CMakeで`-DENABLE_SELINUX=ON`を指定すると、インストール時にモジュールの読み込みとラベルの付け直しまで行います。  

```sh
cd hazkey-community
mkdir build && cd build

cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DENABLE_SELINUX=ON \
      ..
ninja -j $(nproc)
sudo ninja install

# 読み込み前から動作している変換サーバを終了する (次のキー入力で、新しいドメインで自動的に再起動される)
pkill -u $USER -f '^([^ ]*/)?hazkey-community-server( |$)'
```

<br>

## 詳細な文書

リリースに添付したビルド済みのモジュール (`.pp`ファイル) の利用、`Makefile`による単独のビルド、Booleanの設定、トラブルシューティング、  
アンインストールは、[selinux/README.md](../selinux/README.md)を参照してください。  

ポリシーの設計、各規則が必要な理由、カスタマイズ、監査の方法は、管理者向けの[selinux/ADMIN.md](../selinux/ADMIN.md)を参照してください。  
