## Current Todo 6 fork pins

The persistent non-spinning CPU ggml threadpool is implemented permanently on
the fork branches, not as an apply-at-build patch:

- **llama.cpp submodule:** `27d0bacc595e46cca1de100f2041e1b5ea207773`, commit
  `27d0bac hazkey: add non-spinning CPU threadpool helper`.
- **Converter dependency:** `39854feec68fae2ccfa946213faa6369ccf73a54`, which
  includes `07eb1bc hazkey: reuse a non-spinning CPU ggml threadpool`,
  `71181e8 hazkey: make CPU threadpool storage concurrency-safe`, and
  `39854fe hazkey: store CPU threadpool state safely`.

The converter acquires the pool only for CPU contexts, reuses it across
compatible contexts, and releases the final lease during context teardown.
No `patches/*.patch` file implements this threadpool wiring.

## Patch inventory

- **0001 — retired.** Formerly `0001-zenzai-pin-vulkan-icd.patch` (pinned a single Vulkan ICD before `ggml_backend_load_all()` to mitigate the multi-GPU SIGILL, hazkey issue [#29](https://github.com/7ka-Hiira/hazkey/issues/29)). This is now carried as a commit on the converter fork instead of an apply-at-build patch: `presire/AzooKeyKanaKanjiConverter`, `hazkey` branch, commit `723e43d hazkey: pin Vulkan ICD before backend init and add inference timing seam` (`pinVulkanICDIfNeeded()` in `ZenzContext.swift`, called from `ZenzBackend.initializeIfNeeded()` before `llama_backend_init()`). The patch file was removed from this directory.

- **0002 — retired patch** (earlier retirement, unrelated to this update). Its `GGML_VULKAN_SHADER_MAX_PARALLEL` support is now the commit `hazkey: restore GGML_VULKAN_SHADER_MAX_PARALLEL env-var support` on the `presire/llama.cpp` `hazkey` branch. The patch file was deleted in commit `c352b6f`.

- **0003 — `0003-fix-standalone-unit-japanese-number.patch`** (unchanged; still an apply-at-build patch).
  - **Target repository:** the pinned `AzooKeyKanaKanjiConverter` fork.
  - **Target file path:** `Sources/KanaKanjiConverterModule/DictionaryManagement/JapaneseNumber.swift`.
  - **Purpose:** allow standalone Japanese number-unit readings such as `じゅう`, `ひゃく`, and `せん` to reach `parseTokens()` instead of being rejected before their implied-one handling.
  - **Apply site, gating, idempotency:** `hazkey-server/build_swift.cmake` applies it unconditionally (not gated by `HAZKEY_SERVER_ZENZAI_TRAIT`, since `JapaneseNumber.swift` is part of the core `KanaKanjiConverterModule`) against the SwiftPM scratch checkout `${CMAKE_CURRENT_BINARY_DIR}/swift-build/checkouts/AzooKeyKanaKanjiConverter`, after an explicit `swift package resolve --scratch-path=...` step. It is skipped (idempotent) when the checkout already contains the anchor string `hazkey-community patch`; a failed `git apply` only warns and does not fail the build. In the CI XCTest path, `.github/workflows/test.yml` applies the same patch (same anchor guard) against the ordinary `.build/checkouts/AzooKeyKanaKanjiConverter` checkout before `swift test`.

- **0006 — `0006-zenzai-preserve-user-dictionary.patch`** (apply-at-build patch).
  - **Target repository:** the pinned `AzooKeyKanaKanjiConverter` fork.
  - **Target file path:** `Sources/KanaKanjiConverterModule/ConversionAlgorithms/Zenzai/zenzai.swift`.
  - **Purpose:** when `review()` receives the same `fixRequired` or `wholeResult` constraint twice, preserve a candidate containing `.isFromUserDictionary` by taking the existing give-up path instead of enabling `ignoreMemoryAndUserDictionary`; the existing retry remains for `.isLearned`-only candidates.
  - **Apply site, gating, idempotency:** `hazkey-server/build_swift.cmake` applies it after the same explicit SwiftPM scratch-checkout resolve as 0003. It is unconditional so the checkout is patched consistently, but uses the 0006-specific `grep -q "hazkey-community patch.*Preserve explicitly registered user-dictionary candidates"` guard because `zenzai.swift` already contains unrelated community-patch markers. The CMake apply failure only warns and does not fail the build. In the CI XCTest path, `.github/workflows/test.yml` applies the same anchor-guarded patch against the ordinary `.build/checkouts/AzooKeyKanaKanjiConverter` checkout before `swift test`.

- **0004 — retired.** Formerly `0004-zenzai-inference-timer.patch` (added the env-gated `ZenzInferencePerf` accumulator around `get_logits`). Ported together with 0001 in the same fork commit: `723e43d hazkey: pin Vulkan ICD before backend init and add inference timing seam`. The patch file was removed from this directory.

- **0005 — retired.** Formerly `0005-zenzai-llama-memory-api.patch` (migrated the converter from the removed KV-cache API to llama.cpp's `llama_memory_*` API, plus the six vendored header refresh). Split across two fork commits: `903cf04 hazkey: refresh vendored llama.cpp headers to hazkey pin 9d4f2c3f5` (the header/modulemap part) and `5c2ad77 hazkey: migrate to llama_memory_* API` (the `ZenzContext.swift` / `llama-mock.swift` call-site migration). The patch file was removed from this directory.

## Why the switch: apply-at-build patches -> a fork branch

0001, 0004, and 0005 all touched files (`ZenzContext.swift`, vendored `llama.cpp` headers) inside the `AzooKeyKanaKanjiConverter` checkout that upstream refactored twice already, which broke the patches' apply-site assumptions and forced repeated maintenance. Those three are now ordinary commits on `presire/AzooKeyKanaKanjiConverter`'s `hazkey` branch (base `93766c4`), which `hazkey-server/Package.swift` depends on directly, so there is nothing left to apply for them at build time. 0003 and 0006 stay as patches because their target files have been stable and the patches still apply cleanly; there was no forcing reason to fold them into fork commits yet.

**Fork commits (in order, tip first):**
```
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
(`53128a2` is a new capability — GPU/CPU device selection — not a port of any retired patch; it is listed here because it sits on the same fork branch between the header refresh and the ICD-pin/perf-seam commits.)

**Fork availability.** `presire/AzooKeyKanaKanjiConverter`'s `hazkey` branch is pushed to GitHub at `https://github.com/presire/AzooKeyKanaKanjiConverter`, with tip `39854feec68fae2ccfa946213faa6369ccf73a54`. `hazkey-server/Package.swift` resolves that remote URL directly with `branch: "hazkey"`; no local `/tmp` clone is required to build or resolve the converter dependency.

## Apply-order narrative (current state)

There are now two converter patches left to apply at build time: 0003 and 0006. `hazkey-server/build_swift.cmake` runs a `swift package resolve` step first (to materialize the SwiftPM scratch checkout), then applies 0003 and 0006 unconditionally against that checkout, then runs the actual `swift build`. There is no trait gating or dependency between the two patches: the former `0001 -> 0004 -> 0005 -> 0003` chain no longer exists in `build_swift.cmake` because 0001/0004/0005 have no apply step at all now. `.github/workflows/test.yml` mirrors this: it resolves the package, applies the 0003 and 0006 anchor-guarded patches, then runs `swift test --traits ZenzaiSupport`.

## Measured apply-site facts

- `hazkey-server/build_swift.cmake` resolves the converter checkout with `swift package resolve --scratch-path=${CMAKE_CURRENT_BINARY_DIR}/swift-build` before applying anything; the CMake build consumes `${CMAKE_CURRENT_BINARY_DIR}/swift-build/checkouts/AzooKeyKanaKanjiConverter`.
- The 0003 apply step is guarded by `grep -q "hazkey-community patch" ${NUMBER_TARGET_FILE}` and only runs `git apply` when that anchor is absent, so re-running the CMake build against an already-patched checkout is a no-op. The 0006 step uses its unique `grep -q "hazkey-community patch.*Preserve explicitly registered user-dictionary candidates" ${USER_DICTIONARY_TARGET_FILE}` guard for the same reason, without mistaking unrelated markers in `zenzai.swift` for its own application.
- The CI XCTest job (`.github/workflows/test.yml`) uses an ordinary `swift package resolve` (not a scratch path), so its checkout is `.build/checkouts/AzooKeyKanaKanjiConverter`; it applies the same 0003 and 0006 patches with their respective anchor guards before `swift test --traits ZenzaiSupport`.
- No workflow file references 0001, 0004, or 0005 anymore (`.github/workflows/test.yml` and `.github/workflows/build.yml` were checked; the 0003 and 0006 apply blocks remain).

## llama.cpp dependency surface

The CMake build in `hazkey-server/CMakeLists.txt` passes the following llama.cpp configuration surface: `BUILD_SHARED_LIBS=ON`, `LLAMA_CURL=OFF`, `LLAMA_STANDALONE=OFF`, `GGML_NATIVE=OFF`, `GGML_BACKEND_DL=ON`, `GGML_CPU_ALL_VARIANTS=ON`, `GGML_CPU=ON`, the `GGML_VULKAN` option (default ON), `GGML_CUDA=OFF`, `GGML_HIP=OFF`, and install rpath `$ORIGIN`.

The C API is also a header ABI boundary. The converter fork ships its own `Sources/llama.cpp/module.modulemap` (refreshed by fork commit `903cf04` for pin `9d4f2c3f5`, then again by `2bd54a6` for pin `00842b94` and extended by `07eb1bc` for the CPU-threadpool helper at pin `27d0bacc`), which now exposes seven headers — `llama.h`, `ggml.h`, `ggml-alloc.h`, `ggml-backend.h`, `ggml-cpu.h`, `ggml-opt.h`, and `gguf.h` (newly added at pin `00842b94`) — and links `llama`, `ggml`, and `ggml-base`. Because the header refresh is now a fork commit rather than a patch, a future llama.cpp bump means updating the fork's vendored headers directly (see FUTURE update procedure below), not editing a patch file.

The model-format axis is independent but coupled to the upgrade decision: the submodule pins `presire/llama.cpp` on its `hazkey` branch at `27d0bacc595e46cca1de100f2041e1b5ea207773` (`hazkey: add non-spinning CPU threadpool helper`, updated from `00842b94eaa7c7c6b2f11c394f049711f6d20718` on 2026-09-02), and the installed `zenzai.gguf` must remain loadable by that library. Compatibility cannot be inferred only from a successful CMake compile.

The inherited build-time requirement at pin `27d0bacc`: upstream `ggml/src/ggml-vulkan/CMakeLists.txt` runs `find_package(SPIRV-Headers CONFIG REQUIRED)`, and the `ggml-vulkan` target does not propagate the found package's include directory to the compiler, so a locally provisioned SPIRV-Headers prefix must be handed to CMake *and* to the compiler. The exact recipe used for the 2026-09-01 sync (no sudo, everything under `/tmp/opencode`):

1. `git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git /tmp/opencode/spirv-headers-src`
2. `cmake -S /tmp/opencode/spirv-headers-src -B /tmp/opencode/spirv-headers-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/tmp/opencode/spirv-headers-prefix && cmake --build /tmp/opencode/spirv-headers-build -j$(nproc) && cmake --install /tmp/opencode/spirv-headers-build` — this installs `share/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake` and `include/spirv/unified1/spirv.hpp` into the prefix.
3. Configure the hazkey build with `VULKAN_SDK=/tmp/opencode/spirv-headers-prefix`, `SPIRV-Headers_DIR=/tmp/opencode/spirv-headers-prefix/share/cmake/SPIRV-Headers` (the variable name contains a hyphen, so inject it via `env 'SPIRV-Headers_DIR=...' cmake ...`), and `CXXFLAGS=-I/tmp/opencode/spirv-headers-prefix/include` (lands in `CMAKE_CXX_FLAGS`; without it `ggml-vulkan.cpp` fails on the missing `spirv/unified1/spirv.hpp`).

Once a distro `spirv-headers-devel` package places `spirv/unified1/spirv.hpp` on a default compiler include path, the local prefix (and `CXXFLAGS`) is no longer needed.

The Zenzai path currently depends on these llama.cpp API families: `llama_backend_init`, `ggml_backend_load_all`, `llama_model_load*`, `llama_init_from_model`, `llama_get_memory`, `llama_memory_seq_pos_max`, `llama_memory_seq_rm`, `llama_memory_seq_cp`, `llama_batch_init`, `llama_batch_add`, `llama_batch_free`, `llama_decode`, `llama_get_logits`, `llama_n_ctx`, and `llama_vocab_n_tokens`. Treat the `llama_memory_*` family as historically churn-prone and review its semantics and signatures first during an upgrade.

## FUTURE update procedure

The `hazkey-converter-fork-update` plan moved 0001, 0004, and 0005 onto the fork's `hazkey` branch as ordinary commits (`903cf04`, `5c2ad77`, `53128a2`, `723e43d`, on top of upstream `93766c4`); the 2026-09-01 llama.cpp upstream sync added `2bd54a6` (header refresh for pin `00842b94`) and `e4fba90` (minimal compile fixes for that pin). Todo 6 then added `07eb1bc`, `71181e8`, and `39854fe` for the persistent CPU pool and its concurrency-safe storage. Future maintenance follows the same model the `presire/llama.cpp` fork already uses:

1. To pull in upstream `azooKey/AzooKeyKanaKanjiConverter` changes, run `git merge azooKey/main` (or the equivalent upstream remote) into the fork's `hazkey` branch in the local clone, then rebase the `hazkey:` commits on top if the merge produces conflicts in the files they touch (`ZenzContext.swift`, `ConvertRequestOptions.swift`, `llama-mock.swift`, `Sources/llama.cpp/*`).
2. When `hazkey-server/llama.cpp` (the submodule) is bumped to a new pin, refresh the fork's vendored headers (`Sources/llama.cpp/llama.h`, `ggml.h`, `ggml-alloc.h`, `ggml-backend.h`, `ggml-cpu.h`, `ggml-opt.h`, `gguf.h`) and `module.modulemap` from that new pin, mirroring what fork commit `903cf04` did for pin `9d4f2c3f5`, what `2bd54a6` did for pin `00842b94`, and what `07eb1bc` did to expose the `27d0bacc` CPU-threadpool helper. Add a new `hazkey:` commit for it. For pins whose `ggml-vulkan` requires `find_package(SPIRV-Headers)` (as `27d0bacc` does), provision the local SPIRV-Headers prefix and build-time env per the recipe in the llama.cpp dependency surface section before configuring.
3. 0003 and 0006 remain standalone patches; revalidate both against the new fork tip before trusting `build_swift.cmake`'s idempotency checks. 0003 uses the generic `hazkey-community patch` string in `JapaneseNumber.swift`; 0006 uses its unique preservation-comment anchor in `zenzai.swift` because that file already has other community-patch markers.
4. Re-run the receipt matrix: fork-side traited (`swift build --traits Zenzai`) and untraited (`swift build`) compile checks, then the full hazkey-server suite (`swift test --traits ZenzaiSupport`), the `HAZKEY_PARITY` candidate-parity gate, and the `HAZKEY_BENCH` inference-seam differential. Do not apply changes directly to a real (non-disposable) checkout.
5. Push every future `hazkey` branch update to `https://github.com/presire/AzooKeyKanaKanjiConverter` and record the resulting tip SHA alongside any `hazkey-server/Package.swift` dependency change.

All prior acceptance gates from the llama.cpp-update procedure still apply to any future update that touches this dependency:

1. **OutputParity suite** passes.
2. **Real-model benchmark gate:** `HAZKEY_BENCH=1` `InferenceSeamBenchmarkTests` passes with the real model.
3. **Multi-ICD SIGILL regression gate:** with two or more ICDs installed, `pinVulkanICDIfNeeded()` (fork commit `723e43d`) prevents the issue-#29 startup regression.
4. **CPU fallback gate:** a `GGML_VULKAN=OFF` build passes.
5. **Submodule-pointer / dependency-pin gate:** the recorded submodule pointer and the converter fork tip SHA are the reviewed intended revisions, and the working tree is clean.

Receipts for this switch-over are in `../../../.omo/evidence/hazkey-converter-fork-update/` (relative to this README's directory; the `.omo/` directory sits beside this repository checkout, outside version control).
