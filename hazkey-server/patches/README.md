## 現在のTodo 6フォークピン (fork pins)

常駐型の非スピンCPU ggmlスレッドプールは、ビルド時適用パッチ (apply-at-build patch) としてではなく、フォークブランチ上に恒久的に実装されています:  

- **llama.cppサブモジュール:**  
  `27d0bacc595e46cca1de100f2041e1b5ea207773`  
  コミット `27d0bac hazkey: add non-spinning CPU threadpool helper`  
- **コンバータ依存 (converter dependency):**  
  `hazkey-server/Package.resolved` により `0dfc0e5a37dbe38ce87a65a6d67f943901a4867b` (2026-09-11) にピン留めされています。
  これには、`07eb1bc hazkey: reuse a non-spinning CPU ggml threadpool`、`71181e8 hazkey: make CPU threadpool storage concurrency-safe`、  
  `39854fe hazkey: store CPU threadpool state safely`、および上流 `ad714fe` のマージ、  
  焼き込み済みの0006修正 (`2cef753`)、ベンダー対応Vulkan ICDピン留め (`0dfc0e5`) が含まれます。  

コンバータはCPUコンテキストでのみプールを取得し、互換性のあるコンテキスト間で再利用し、コンテキスト破棄時に最後のリースを解放します。  
このスレッドプール配線を実装する `patches/*.patch` ファイルは存在しません。  

## パッチ一覧 (patch inventory)

- **0001 — 廃止 (retired)**  
  旧 `0001-zenzai-pin-vulkan-icd.patch`  
  (マルチGPU環境のSIGILLを緩和するため、`ggml_backend_load_all()` の前に単一のVulkan ICDを固定するもの。  
  hazkey issue [#29](https://github.com/7ka-Hiira/hazkey/issues/29))  
  
  これは現在、ビルド時適用パッチではなくコンバータフォーク上のコミットとして保持されています:  
  `presire/AzooKeyKanaKanjiConverter` の `hazkey` ブランチ  
  コミット `723e43d hazkey: pin Vulkan ICD before backend init and add inference timing seam`  
  (`ZenzContext.swift` 内の `pinVulkanICDIfNeeded()` で、`ZenzBackend.initializeIfNeeded()` から `llama_backend_init()` の前に呼び出されます)  
  
  パッチファイルはこのディレクトリから削除されました。  
  
- **0002 — 廃止済みパッチ (retired patch)** (今回の更新とは無関係の、以前の廃止)  
  その `GGML_VULKAN_SHADER_MAX_PARALLEL` 対応は、  
  現在、`presire/llama.cpp` の `hazkey` ブランチ上のコミット `hazkey: restore GGML_VULKAN_SHADER_MAX_PARALLEL env-var support` です。  
  パッチファイルはコミット `c352b6f` で削除されました。  
  
- **0003 - `0003-fix-standalone-unit-japanese-number.patch`** (変更なし。引き続きビルド時適用パッチ)  
  - **対象リポジトリ:**  
    ピン留めされた `AzooKeyKanaKanjiConverter` フォーク  
  - **対象ファイルパス:**  
    `Sources/KanaKanjiConverterModule/DictionaryManagement/JapaneseNumber.swift`  
  - **目的:**  
    `じゅう`、`ひゃく`、`せん` のような単独の日本語数詞単位の読みが、暗黙の「1」処理の前に拒否されることなく `parseTokens()` に到達できるようにする。  
  - **適用サイト・ゲート・冪等性 (apply site, gating, idempotency):**  
    `hazkey-server/build_swift.cmake` が、明示的な `swift package resolve --scratch-path=...` ステップの後に、  
    SwiftPMのスクラッチチェックアウト `${CMAKE_CURRENT_BINARY_DIR}/swift-build/checkouts/AzooKeyKanaKanjiConverter` に対して無条件で適用します。  
    (`JapaneseNumber.swift` はコアの `KanaKanjiConverterModule` の一部であるため、`HAZKEY_SERVER_ZENZAI_TRAIT` によるゲートはありません)  
    チェックアウトに既にアンカー文字列 `hazkey-community patch` が含まれている場合はスキップされます。(冪等)  
    `git apply` が失敗した場合も警告のみで、ビルドは失敗しません。  
    CIのXCTest経路では、`.github/workflows/test.yml` が `swift test` の前に、  
    通常の `.build/checkouts/AzooKeyKanaKanjiConverter` チェックアウトに対して同じパッチ (同じアンカーガード) を適用します。  
  
- **0006 - 廃止 (retired)**  
  旧 `0006-zenzai-preserve-user-dictionary.patch`  
  (`review()` が同じ `fixRequired` または `wholeResult` 制約を2回受け取った際、`ignoreMemoryAndUserDictionary` を有効化する代わりに既存のギブアップ経路をたどることで、`.isFromUserDictionary` を含む候補を保持するもの。`.isLearned` のみの候補には既存のリトライが残されていました)  
  
  2026-09-08、上流コミット `ad714fe` (#357、accepted-prediction prefix constraint) が `zenzai.swift` の `normalizedZenzConstraint()` 呼び出しサイトを変更し、  
  パッチの適用コンテキストが壊れたため廃止。  

  修正は現在、コンバータフォーク上のコミットとして保持されています:  
  `presire/AzooKeyKanaKanjiConverter` の `hazkey` ブランチ、  
  コミット `2cef753 hazkey: preserve explicitly registered user-dictionary candidates across constraint retries`  
  (`cfebb64` で `ad714fe` をマージする際に焼き込み済み)  

  `build_swift.cmake` のマーカーガードとCI XCTestのアンカーガードは、いずれにせよ適用ステップをスキップしたはずですが、  
  不要になったパッチファイルとその適用ブロックは削除されました。  

  パッチファイルはこのディレクトリから削除されました。  
  
- **0004 - 廃止 (retired)**  
  旧 `0004-zenzai-inference-timer.patch` (`get_logits` の周囲に環境変数でゲートされる `ZenzInferencePerf` アキュムレータを追加するもの)  
  0001と同じフォークコミット `723e43d hazkey: pin Vulkan ICD before backend init and add inference timing seam` で一緒に移植されました。  
  パッチファイルはこのディレクトリから削除されました。  
  
- **0005 - 廃止 (retired)**  
  旧 `0005-zenzai-llama-memory-api.patch`  
  (削除されたKVキャッシュAPIからllama.cppの `llama_memory_*` APIへのコンバータ移行、およびベンダリング済みヘッダ6件のリフレッシュ)  
  
  2つのフォークコミットに分割されました:  
  `903cf04 hazkey: refresh vendored llama.cpp headers to hazkey pin 9d4f2c3f5` (ヘッダ/modulemap部分) と  
  `5c2ad77 hazkey: migrate to llama_memory_* API` (`ZenzContext.swift` / `llama-mock.swift` の呼び出しサイト移行)  
  
  パッチファイルはこのディレクトリから削除されました。

## 切り替えの理由: ビルド時適用パッチ (apply-at-build patch) → フォークブランチ

0001、0004、0005はすべて、  
上流が既に2度リファクタリングしていた `AzooKeyKanaKanjiConverter` チェックアウト内のファイル (`ZenzContext.swift`、ベンダリング済み `llama.cpp` ヘッダ) に触れていたため、  
パッチの適用サイトの前提が壊れ、繰り返しのメンテナンスを強いられました。  

0006も同じ理由で2026-09-08に合流しました:  
上流 `ad714fe` が `zenzai.swift` の `normalizedZenzConstraint()` 呼び出しサイトをリファクタリングし、コンテキストが壊れたためです。  
4件はすべて現在、`presire/AzooKeyKanaKanjiConverter` の `hazkey` ブランチ上の通常のコミットであり、`hazkey-server/Package.swift` が直接依存しているため、  
ビルド時に適用すべきものは残っていません。  

0003だけがビルド時適用パッチとして残っています。  

対象ファイル (`JapaneseNumber.swift`) が安定しており、パッチが今もクリーンに適用できるためで、フォークコミットへ折り込む必然性がまだないためです。  

**フォークコミット (順序: tipが先頭):**  

```
2cef753 hazkey: preserve explicitly registered user-dictionary candidates across constraint retries
cfebb64 Merge commit 'ad714fe' into hazkey   (brings upstream ad714fe #357)
20dc65d feat: add learning memory enumeration API
38ef2fa hazkey: treat GGML integrated-GPU devices as GPU-capable in device selection
59b529b hazkey: remove unconditional candidate dump from predictive input path
9064a9b hazkey: propagate Zenzai device config through model construction
39854fe hazkey: store CPU threadpool state safely
71181e8 hazkey: make CPU threadpool storage concurrency-safe
07eb1bc hazkey: reuse a non-spinning CPU ggml threadpool
e4fba90 hazkey: minimal compile fixes for llama.cpp pin 00842b94
2bd54a6 hazkey: refresh vendored llama.cpp headers to hazkey pin 00842b94
723e43d hazkey: pin Vulkan ICD before backend init and add inference timing seam
53128a2 hazkey: port device config API for GPU/CPU selection
5c2ad77 hazkey: migrate to llama_memory_* API
903cf04 hazkey: refresh vendored llama.cpp headers to hazkey pin 9d4f2c3f5
```

> `53128a2` は新しい機能 - GPU/CPUデバイス選択 - であり、廃止されたパッチの移植ではありません。  
> ヘッダリフレッシュとICDピン留め/perfシームのコミットの間で同じフォークブランチ上にあるため、ここに記載しています。  

**フォークの公開状況 (fork availability)**  
`presire/AzooKeyKanaKanjiConverter` の `hazkey` ブランチは `https://github.com/presire/AzooKeyKanaKanjiConverter` にプッシュされており、  
tipは `0dfc0e5a37dbe38ce87a65a6d67f943901a4867b` です。  

> 2026-09-11のベンダー対応Vulkan ICDピン留め。  
> 以前は `2cef753a03e73560e1c83137aabf0416936dd64d` で、2026-09-08に上流 `ad714fe` をマージし、  
> 焼き込み済み0006修正を含んでいました。  

`hazkey-server/Package.swift` はそのリモートURLを `branch: "hazkey"` で直接解決するため、  
コンバータ依存のビルドや解決にローカルの `/tmp` クローンは不要です。  

## 適用順序の説明 (現状)

ビルド時に適用するコンバータパッチは現在0003の1つだけです。  

`hazkey-server/build_swift.cmake` は、  
まず `swift package resolve` ステップを実行して (SwiftPMのスクラッチチェックアウトを実体化するため)、  
そのチェックアウトに対して0003を無条件に適用し、その後実際の `swift build` を実行します。  

以前の `0001 -> 0004 -> 0005 -> 0003` の連鎖は、0001/0004/0005/0006に適用ステップがまったくなくなったため、  
`build_swift.cmake` にはもう存在しません。  

`.github/workflows/test.yml` も同様で、パッケージを解決し、  
アンカーガード付きの0003パッチを適用してから `swift test --traits ZenzaiSupport` を実行します。  

## 適用サイトの実測事実 (measured apply-site facts)

- `hazkey-server/build_swift.cmake`  
  何かを適用する前に `swift package resolve --scratch-path=${CMAKE_CURRENT_BINARY_DIR}/swift-build` でコンバータのチェックアウトを解決します。  
  CMakeビルドが使用するのは `${CMAKE_CURRENT_BINARY_DIR}/swift-build/checkouts/AzooKeyKanaKanjiConverter` です。  
- 0003の適用ステップは `grep -q "hazkey-community patch" ${NUMBER_TARGET_FILE}` でガードされ、  
  アンカーが存在しない場合にのみ `git apply` を実行します。  
  そのため、パッチ適用済みのチェックアウトに対してCMakeビルドを再実行しても何も行われません。(no-op)  
- CIのXCTestジョブ (`.github/workflows/test.yml`) は通常の `swift package resolve` (スクラッチパスではない) を使用するため、  
  チェックアウトは `.build/checkouts/AzooKeyKanaKanjiConverter` です。  
  `swift test --traits ZenzaiSupport` の前に、同じアンカーガード付きで同じ0003パッチを適用します。  
- どのワークフローファイルも0001、0004、0005、0006をもう参照していません。  
  (`.github/workflows/test.yml` と `.github/workflows/build.yml` を確認済み。残っているのは0003の適用ブロックのみ)  

## llama.cpp の依存サーフェス (dependency surface)

`hazkey-server/CMakeLists.txt` のCMakeビルドは、以下のllama.cpp設定サーフェスを渡します:  
`BUILD_SHARED_LIBS=ON`、`LLAMA_CURL=OFF`、`LLAMA_STANDALONE=OFF`、`GGML_NATIVE=OFF`、`GGML_BACKEND_DL=ON`、  
`GGML_CPU_ALL_VARIANTS=ON`、`GGML_CPU=ON`、`GGML_VULKAN` オプション (デフォルトON)、`GGML_CUDA=OFF`、`GGML_HIP=OFF`、およびインストールRPATH `$ORIGIN`  

C APIはヘッダABIの境界でもあります。  
コンバータフォークは独自の `Sources/llama.cpp/module.modulemap` を同梱しており  
(フォークコミット `903cf04` がピン `9d4f2c3f5` 向けに、続いて `2bd54a6` がピン `00842b94` 向けにリフレッシュし、さらに `07eb1bc` がピン `27d0bacc` のCPUスレッドプールヘルパー向けに拡張)、  
現在は7つのヘッダ — `llama.h`、`ggml.h`、`ggml-alloc.h`、`ggml-backend.h`、`ggml-cpu.h`、`ggml-opt.h`、`gguf.h` (ピン `00842b94` で新規追加) — を公開し、  
`llama`、`ggml`、`ggml-base` をリンクします。  

ヘッダリフレッシュは現在パッチではなくフォークコミットであるため、将来llama.cppを更新する場合は、パッチファイルを編集するのではなく、  
フォークのベンダリング済みヘッダを直接更新します。(後述の「今後の更新手順」参照)  

モデルフォーマットの軸は独立していますが、アップグレード判断とは結合しています:  
サブモジュールは `presire/llama.cpp` の `hazkey` ブランチを `27d0bacc595e46cca1de100f2041e1b5ea207773`  
(`hazkey: add non-spinning CPU threadpool helper`。2026-09-02に `00842b94eaa7c7c6b2f11c394f049711f6d20718` から更新) にピン留めしており、  
インストールされる `zenzai.gguf` はそのライブラリでロード可能であり続ける必要があります。  

互換性はCMakeのコンパイルが通っただけでは判断できません。  

ピン `27d0bacc` で引き継がれているビルド時要件:  
上流の `ggml/src/ggml-vulkan/CMakeLists.txt` が `find_package(SPIRV-Headers CONFIG REQUIRED)` を実行し、  
`ggml-vulkan` ターゲットは見つけたパッケージのインクルードディレクトリをコンパイラへ伝播しないため、  
ローカルに用意したSPIRV-HeadersプレフィックスをCMake *と* コンパイラの両方に渡す必要があります。  

2026-09-01の同期で使用した正確な手順 (sudoなし、すべて `/tmp/opencode` 配下):  

1. `git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git /tmp/opencode/spirv-headers-src`  
2. `cmake -S /tmp/opencode/spirv-headers-src -B /tmp/opencode/spirv-headers-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/tmp/opencode/spirv-headers-prefix && cmake --build /tmp/opencode/spirv-headers-build -j$(nproc) && cmake --install /tmp/opencode/spirv-headers-build`  
   これにより `share/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake` と `include/spirv/unified1/spirv.hpp` がプレフィックスにインストールされます。  
3. hazkeyのビルドを、`VULKAN_SDK=/tmp/opencode/spirv-headers-prefix`、`SPIRV-Headers_DIR=/tmp/opencode/spirv-headers-prefix/share/cmake/SPIRV-Headers` (変数名にハイフンが含まれるため、`env 'SPIRV-Headers_DIR=...' cmake ...` のようにして注入します)、  
   および `CXXFLAGS=-I/tmp/opencode/spirv-headers-prefix/include` (`CMAKE_CXX_FLAGS` に入ります。これがないと `ggml-vulkan.cpp` が `spirv/unified1/spirv.hpp` を見つけられず失敗します) でconfigureします。  

ディストリビューションの `spirv-headers-devel` パッケージが `spirv/unified1/spirv.hpp` をコンパイラのデフォルトインクルードパスに配置するようになれば、  
ローカルプレフィックス (および `CXXFLAGS`) は不要になります。  

Zenzaiの経路は現在、以下のllama.cpp APIファミリに依存しています:  
`llama_backend_init`、`ggml_backend_load_all`、`llama_model_load*`、`llama_init_from_model`、`llama_get_memory`、  
`llama_memory_seq_pos_max`、`llama_memory_seq_rm`、`llama_memory_seq_cp`、`llama_batch_init`、`llama_batch_add`、  
`llama_batch_free`、`llama_decode`、`llama_get_logits`、`llama_n_ctx`、`llama_vocab_n_tokens`。`llama_memory_*` ファミリは歴史的に変更が激しいため、  
アップグレード時はそのセマンティクスとシグネチャを最初に確認してください。  

## 今後の更新手順 (FUTURE update procedure)

`hazkey-converter-fork-update` 計画により、0001、0004、0005は通常のコミットとしてフォークの `hazkey` ブランチへ移動しました。  
(`903cf04`、`5c2ad77`、`53128a2`、`723e43d`。上流 `93766c4` の上)  

2026-09-01のllama.cpp上流同期で `2bd54a6` (ピン `00842b94` 向けヘッダリフレッシュ) と `e4fba90` (同ピン向けの最小コンパイル修正) が追加されました。  
その後Todo 6で、常駐CPUプールとその並行安全なストレージのために `07eb1bc`、`71181e8`、`39854fe` が追加されました。  

今後のメンテナンスは、`presire/llama.cpp` フォークが既に採用しているのと同じモデルに従います:  

1. 上流 `azooKey/AzooKeyKanaKanjiConverter` の変更を取り込むには、  
   ローカルクローンでフォークの `hazkey` ブランチに `git merge azooKey/main` (または同等の上流リモート) を実行し、  
   マージが対象ファイル (`ZenzContext.swift`、`ConvertRequestOptions.swift`、`llama-mock.swift`、`Sources/llama.cpp/*`) で競合を生じた場合は、  
  `hazkey:` コミットをその上にrebaseします。  
2. `hazkey-server/llama.cpp` (サブモジュール) を新しいピンへ更新したら、  
   その新しいピンからフォークのベンダリング済みヘッダ (`Sources/llama.cpp/llama.h`、`ggml.h`、`ggml-alloc.h`、`ggml-backend.h`、`ggml-cpu.h`、`ggml-opt.h`、`gguf.h`) と  
   `module.modulemap` をリフレッシュします。  
   フォークコミット `903cf04` がピン `9d4f2c3f5` に対して行ったこと、`2bd54a6` がピン `00842b94` に対して行ったこと、  
   `07eb1bc` が `27d0bacc` のCPUスレッドプールヘルパーを公開するために行ったことを踏襲してください。  
   そのための新しい `hazkey:` コミットを追加します。  
   `ggml-vulkan` が `find_package(SPIRV-Headers)` を要求するピン (`27d0bacc` など) では、  
   configureの前に「llama.cpp の依存サーフェス」節の手順に従ってローカルSPIRV-Headersプレフィックスとビルド時環境を用意します。  
3. 0003だけが唯一のスタンドアロンパッチとして残ります。  
   `build_swift.cmake` の冪等性チェック (`JapaneseNumber.swift` 内の汎用文字列 `hazkey-community patch` を使用) を信頼する前に、  
   新しいフォークtipに対して0003を再検証してください。  
   
   廃止されたパッチ (0001、0004、0005、0006) はフォークコミットとして存在するため、  
   それらの対象ファイルに触れる上流マージでは、パッチの再検証ではなく、焼き込み済みの挙動が引き続きコンパイル・動作することを確認する必要があります。  
4. 「レシートマトリクス (receipt matrix)」を再実行します:  
   フォーク側のtraited (`swift build --traits Zenzai`) とuntraited (`swift build`) のコンパイルチェック、  
   続いてhazkey-serverの全スイート (`swift test --traits ZenzaiSupport`)、`HAZKEY_PARITY` 候補パリティゲート、`HAZKEY_BENCH` 推論シーム差分。  
   実環境 (使い捨てでない) のチェックアウトに直接変更を適用しないでください。  
5. 今後の `hazkey` ブランチ更新はすべて `https://github.com/presire/AzooKeyKanaKanjiConverter` にプッシュし、  
   `hazkey-server/Package.swift` の依存変更があれば、その結果のtip SHAも併せて記録してください。  

この依存に触れる今後の更新には、llama.cpp更新手順の従来の受け入れゲート (acceptance gates) がすべて引き続き適用されます:  

1. **OutputParityスイート** がパスすること。  
2. **実モデルベンチマークゲート:**  
   実モデルで `HAZKEY_BENCH=1` の `InferenceSeamBenchmarkTests` がパスすること。  
3. **マルチICD SIGILLリグレッションゲート:**  
   ICDが2つ以上インストールされた状態で、`pinVulkanICDIfNeeded()` (フォークコミット `723e43d`) がissue #29の起動時リグレッションを防ぐこと。  
4. **CPUフォールバックゲート:**  
   `GGML_VULKAN=OFF` のビルドがパスすること。  
5. **サブモジュールポインタ / 依存ピンゲート:**  
   記録されたサブモジュールポインタとコンバータフォークtip SHAが、レビュー済みの意図したリビジョンであり、作業ツリーがクリーンであること。  

この切り替えのレシート (receipts) は `../../../.omo/evidence/hazkey-converter-fork-update/` にあります。  
(このREADMEのディレクトリからの相対パス。`.omo/` ディレクトリはこのリポジトリチェックアウトの隣にあり、バージョン管理外です)  
