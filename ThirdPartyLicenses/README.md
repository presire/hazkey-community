# サードパーティ製ライブラリのライセンス

このディレクトリは、Hazkey Communityの配布パッケージ (.deb / .rpm) に**同梱される**サードパーティ製コンポーネントのライセンス表示を収録するものです。  

パッケージには、hazkey-community-server (Swift実行ファイル)、同梱のlibllamaランタイム、および各種辞書データが含まれ、  
その中には、MIT / Apache-2.0 / BSDで提供される第3者コードと、Unicode License / BSD-3-Clause / 公的データ等にもとづく辞書データが静的にリンク、  
またはデータとして同梱されます。  

これらのライセンスは、バイナリを再頒布する際に著作権表示とライセンス文を同梱することを要求するため、本ディレクトリのファイルをパッケージへ同梱します。  

インストール先:  

- LICENSE (プロジェクト本体) → `/usr/share/hazkey-community/LICENSE`  
- ThirdPartyLicenses/ → `/usr/share/hazkey-community/ThirdPartyLicenses/`  

## 同梱コンポーネント一覧

### 実行ファイルに静的リンクされるSwiftパッケージ

| コンポーネント | 版 / コミット | ライセンス | ファイル |
|---|---|---|---|
| [AzooKeyKanaKanjiConverter](https://github.com/presire/AzooKeyKanaKanjiConverter) (フォーク, hazkeyブランチ) | `102357e` | MIT | [AzooKeyKanaKanjiConverter-LICENSE.txt](./AzooKeyKanaKanjiConverter-LICENSE.txt) |
| [swift-protobuf](https://github.com/apple/swift-protobuf) | 1.38.1 (`55d7a1c`) | Apache-2.0 (Swift Runtime Library Exception付き) | [swift-protobuf-LICENSE.txt](./swift-protobuf-LICENSE.txt) |
| [swift-algorithms](https://github.com/apple/swift-algorithms) | 1.2.1 (`87e50f4`) | Apache-2.0 (Swift Runtime Library Exception付き) | [swift-algorithms-LICENSE.txt](./swift-algorithms-LICENSE.txt) |
| [swift-collections](https://github.com/apple/swift-collections) | 1.6.0 (`a0cb095`) | Apache-2.0 (Swift Runtime Library Exception付き) | [swift-collections-LICENSE.txt](./swift-collections-LICENSE.txt) |
| [swift-numerics](https://github.com/apple/swift-numerics) | 1.1.1 (`0c0290f`) | Apache-2.0 (Swift Runtime Library Exception付き) | [swift-numerics-LICENSE.txt](./swift-numerics-LICENSE.txt) |
| [swift-tokenizers](https://github.com/ensan-hcl/swift-tokenizers) (HuggingFace swift-transformers由来) | 0.0.1 (`4a606f6`) | Apache-2.0 | [swift-tokenizers-LICENSE.txt](./swift-tokenizers-LICENSE.txt) |
| [Jinja](https://github.com/johnmai-dev/Jinja) | 1.1.2 (`31c4dd3`) | MIT | [Jinja-LICENSE.txt](./Jinja-LICENSE.txt) |
| [SwiftyMarisa](https://github.com/ensan-hcl/SwiftyMarisa) | 0.0.1 (`91acc3c`) | BSD-2-Clause (dual: BSD-2-Clause / LGPL-2.1+) | [SwiftyMarisa-LICENSE.txt](./SwiftyMarisa-LICENSE.txt) |
| [marisa-trie](https://github.com/s-yata/marisa-trie) (SwiftyMarisaに同梱) | - | BSD-2-Clause (dual: BSD-2-Clause / LGPL-2.1+) | [marisa-trie-LICENSE.txt](./marisa-trie-LICENSE.txt) |

### 同梱されるランタイムライブラリ

| コンポーネント | 版 / コミット | ライセンス | ファイル |
|---|---|---|---|
| [llama.cpp](https://github.com/presire/llama.cpp) (フォーク, hazkeyブランチ、ggml含む) | `1e148af` | MIT | [llama.cpp-LICENSE.txt](./llama.cpp-LICENSE.txt) |

### 同梱される辞書・データ

| コンポーネント | 版 / コミット | ライセンス | ファイル |
|---|---|---|---|
| [azooKey_dictionary_storage](https://github.com/azooKey/azooKey_dictionary_storage) (Dictionary/) | `4d41852` | Apache-2.0 | [azooKey_dictionary_storage-LICENSE.txt](./azooKey_dictionary_storage-LICENSE.txt) |
| [azooKey_emoji_dictionary_storage](https://github.com/azooKey/azooKey_emoji_dictionary_storage) (emoji_all_E17.0.txt) | `eb15a8d` | Unicode License V3 + BSD-3-Clause | [azooKey_emoji_dictionary_storage-NOTICE.txt](./azooKey_emoji_dictionary_storage-NOTICE.txt) |
| [hazkey-address-dictionary](https://github.com/presire/hazkey-address-dictionary) (AddressDictionary/) | `3876dae` | 日本郵便データ (著作権主張なし) / charIDはApache-2.0 | [hazkey-address-dictionary-NOTICE.txt](./hazkey-address-dictionary-NOTICE.txt) |
| [hazkey-engineering-dictionary](https://github.com/presire/hazkey-engineering-dictionary) (EngineeringDictionary/) | `e50f5a8` | Apache-2.0 + BSD-3-Clause + CC0-1.0 | [hazkey-engineering-dictionary-NOTICE.txt](./hazkey-engineering-dictionary-NOTICE.txt) |

### ライセンス本文

| ファイル | 内容 |
|---|---|
| [Unicode-LICENSE.txt](./Unicode-LICENSE.txt) | Unicode License V3 (絵文字辞書のUnicode/CLDRデータ用) |
| [Mozc-LICENSE.txt](./Mozc-LICENSE.txt) | Mozc BSD 3-Clause License (絵文字辞書・工学用語辞書のデータ用) |

## 同梱されないもの (ビルド時リソース)

以下はビルド時にコンパイルされますが、配布パッケージには**同梱されません**。(参考として表示のみ記載)  

| コンポーネント | ライセンス | ファイル |
|---|---|---|
| EfficientNGram トークナイザデータ ([ku-nlp/gpt2-small-japanese-char](https://huggingface.co/ku-nlp/gpt2-small-japanese-char)由来) | CC BY-SA 4.0 | [EfficientNGram-tokenizer-NOTICE.txt](./EfficientNGram-tokenizer-NOTICE.txt) |

hazkey-community-serverは、SwiftPMのリソースバンドル (AzooKeyKanaKanjiConverter_EfficientNGram.resources等) を参照しますが、  
パッケージはこれをインストールしないため、当該データは頒布物に含まれません。  

## 同梱されないもの (システム依存)

以下は動的にリンクされ、各ディストリビューションのパッケージ / ランタイムとして供給されるため、本ディレクトリには含めません。  
(パッケージ側のDepends / Requiresで宣言)  

- Qt 6 (LGPL-3.0) - hazkey-community-settings  
- Fcitx 5 (LGPL-2.1+) - fcitx5-hazkey-community  
- IBus (LGPL-2.1+) - ibus-hazkey-community  
- libprotobuf-lite (BSD-3-Clause)  
- Vulkan Loader / libvulkan、libncurses、glibc  
- libstdc++ / libgomp (GCC Runtime Library Exception付き)  

## Swiftランタイム

hazkey-community-serverは、Swift標準ライブラリを静的リンクしていますが、  
Swiftランタイムは、Apache-2.0 Licenseの[Runtime Library Exception](https://github.com/swiftlang/swift/blob/main/LICENSE.txt)により、  
リンクしたバイナリの再頒布時に、4(a)・4(b)・4(d)の表示義務が免除されるため、本ディレクトリには含めません。  
