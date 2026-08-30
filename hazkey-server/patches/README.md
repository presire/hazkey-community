## Patch inventory

- **0001 — `0001-zenzai-pin-vulkan-icd.patch`**
  - **Target repository:** the pinned `AzooKeyKanaKanjiConverter` fork (`8b4befc273baafea5964ecf87d3bc36f2bbef68b`).
  - **Target file path:** `Sources/KanaKanjiConverterModule/ConversionAlgorithms/Zenzai/Zenz/ZenzContext.swift`.
  - **Purpose:** before `ggml_backend_load_all()`, pin a multi-ICD Vulkan installation to one ICD. This mitigates hazkey issue [#29](https://github.com/7ka-Hiira/hazkey/issues/29), where mixed GPU ICD loading can lead to an uncatchable SIGILL during Zenzai/Vulkan initialization.
  - **Apply site, order, gating, and idempotency:** `hazkey-server/build_swift.cmake` first resolves the SwiftPM scratch checkout and then applies this first in the converter build stack, `0001 -> 0004 -> 0005 -> 0003`, only when `HAZKEY_SERVER_ZENZAI_TRAIT` is enabled. Its grep idempotency anchor is `pinVulkanICDIfNeeded`. `.github/workflows/test.yml` does not manually apply 0001 in the XCTest-only path.

- **0002 — retired patch**
  - **Permanent home:** its `GGML_VULKAN_SHADER_MAX_PARALLEL` support is now the commit `hazkey: restore GGML_VULKAN_SHADER_MAX_PARALLEL env-var support` on the `presire/llama.cpp` `hazkey` branch. The patch file was deleted in commit `c352b6f`.

- **0003 — `0003-fix-standalone-unit-japanese-number.patch`**
  - **Target repository:** the pinned `AzooKeyKanaKanjiConverter` fork.
  - **Target file path:** `Sources/KanaKanjiConverterModule/DictionaryManagement/JapaneseNumber.swift`.
  - **Purpose:** allow standalone Japanese number-unit readings such as `じゅう`, `ひゃく`, and `せん` to reach `parseTokens()` instead of being rejected before their implied-one handling.
  - **Apply site, order, gating, and idempotency:** `hazkey-server/build_swift.cmake` applies it unconditionally as the final converter build step after `0001 -> 0004 -> 0005`; it is not Zenzai-trait-gated. In the CI XCTest path, `.github/workflows/test.yml` manually applies it in `.build/checkouts/AzooKeyKanaKanjiConverter` before 0004, 0005, and `swift test`. Its grep idempotency anchor is `hazkey-community patch`.

- **0004 — `0004-zenzai-inference-timer.patch`**
  - **Target repository:** the pinned `AzooKeyKanaKanjiConverter` fork.
  - **Target file path:** `Sources/KanaKanjiConverterModule/ConversionAlgorithms/Zenzai/Zenz/ZenzContext.swift`.
  - **Purpose:** add the env-gated `ZenzInferencePerf` accumulator around the complete neural `get_logits` path, giving the server a separable inference-time seam without changing candidate behavior.
  - **Apply site, order, gating, and idempotency:** `hazkey-server/build_swift.cmake` applies it only when `HAZKEY_SERVER_ZENZAI_TRAIT` is enabled, after 0001 and before 0005 and unconditional 0003 in the resolved scratch checkout. In the CI XCTest path, `.github/workflows/test.yml` manually applies it in `.build/checkouts/AzooKeyKanaKanjiConverter` after 0003 and before 0005. Its grep idempotency anchor is `ZenzInferencePerf`.

- **0005 — `0005-zenzai-llama-memory-api.patch`**
  - **Target repository:** the pinned `AzooKeyKanaKanjiConverter` fork (`8b4befc273baafea5964ecf87d3bc36f2bbef68b`).
  - **Target file paths:** `ZenzContext.swift`, `llama-mock.swift`, and six vendored headers: `llama.h`, `ggml.h`, `ggml-alloc.h`, `ggml-backend.h`, newly added `ggml-opt.h`, and `ggml-cpu.h`.
  - **Purpose:** migrate the converter from the removed KV-cache API to llama.cpp's memory API while keeping its Swift mock and vendored C headers ABI-compatible with the pinned llama.cpp fork.
  - **Apply site, order, gating, and idempotency:** `hazkey-server/build_swift.cmake` applies it in the converter stack `0001 -> 0004 -> 0005 -> 0003`; `.github/workflows/test.yml` manually applies `0003 -> 0004 -> 0005` in the XCTest checkout. Its grep idempotency anchor is `llama_memory_seq_pos_max`.

## Measured apply-site facts

- The todo-1 SwiftPM probe established that `swift package resolve --scratch-path <scratch>` owns its checkouts at `<scratch>/checkouts/` and does not create the package-root `.build`. Consequently, the CMake build consumes `build/hazkey-server/swift-build/checkouts/AzooKeyKanaKanjiConverter` after the resolve-first step in `hazkey-server/build_swift.cmake`.
- Before todo 3 rewired the targets, the old `${SWIFT_WORK_DIR}/.build/checkouts/...` build targets were inert: the CMake build had no package-root `.build` checkout to patch. The current scratch target is therefore load-bearing, not a cosmetic path change.
- The CI XCTest job intentionally differs: `.github/workflows/test.yml` runs ordinary `swift package resolve`, so its checkout is `.build/checkouts/AzooKeyKanaKanjiConverter`; it manually applies 0003, 0004, and 0005 before `swift test`.
- Task-5 receipts passed: the disposable converter stack passed `git apply --check` and `git apply` in `0001 -> 0004 -> 0005 -> 0003` order; the CI-compatible stack passed in `0003 -> 0004 -> 0005` order. Deliberate double-apply probes failed as expected, proving the checks discriminate already-applied patches.

**Dominance verdict.** On the recorded CPU backend and fixed warmed corpus, neural inference accounted for a median `0.782312` of candidate generation (`zenzai_inference_ms / candidate_generation_ms`). Real neural work therefore dominates candidate generation on that measurement and justifies planning a llama.cpp update, subject to the future checklist below.

**Receipts.** The detailed application receipts are in `../../../.omo/evidence/hazkey-zenzai-inference/task-5-applycheck.txt` (relative to this README's directory; the `.omo/` directory sits beside this repository checkout, outside version control); the real-model benchmark and dominance evidence are in `../../../.omo/evidence/hazkey-zenzai-inference/task-4-benchmark.txt`. This review references those sources rather than reproducing their command logs.

## llama.cpp dependency surface

The CMake build in `hazkey-server/CMakeLists.txt` passes the following llama.cpp configuration surface: `BUILD_SHARED_LIBS=ON`, `LLAMA_CURL=OFF`, `LLAMA_STANDALONE=OFF`, `GGML_NATIVE=OFF`, `GGML_BACKEND_DL=ON`, `GGML_CPU_ALL_VARIANTS=ON`, `GGML_CPU=ON`, the `GGML_VULKAN` option (default ON), `GGML_CUDA=OFF`, `GGML_HIP=OFF`, and install rpath `$ORIGIN`.

The C API is also a header ABI boundary. The converter fork ships `Sources/llama.cpp/module.modulemap`, which exposes `llama.h`, `ggml.h`, `ggml-alloc.h`, and `ggml-backend.h`, and links `llama`, `ggml`, and `ggml-base`. A llama.cpp bump must update the converter-side headers/fork to match the built `libllama`; compiling against stale fork headers can otherwise create a silent struct-layout or ABI mismatch.

The model-format axis is independent but coupled to the upgrade decision: the submodule now pins `presire/llama.cpp` on its `hazkey` branch at `9d4f2c3f5c2a1749d18ca982130ca1958b1fb5bb`, and the installed `zenzai.gguf` must remain loadable by that library. Compatibility cannot be inferred only from a successful CMake compile.

The Zenzai path currently depends on these llama.cpp API families: `llama_backend_init`, `ggml_backend_load_all`, `llama_model_load*`, `llama_init_from_model`, `llama_get_memory`, `llama_memory_seq_pos_max`, `llama_memory_seq_rm`, `llama_batch_init`, `llama_batch_add`, `llama_batch_free`, `llama_decode`, `llama_get_logits`, `llama_n_ctx`, and `llama_vocab_n_tokens`. Treat the `llama_memory_*` family as historically churn-prone and review its semantics and signatures first during an upgrade.

## FUTURE update procedure

The `hazkey-llama-cpp-update` plan (Session 2) completed this update with submodule pin `9d4f2c3f5c2a1749d18ca982130ca1958b1fb5bb`. This procedure applies to a subsequent update, not to the completed delivery.

1. Start a separate plan with the intended llama.cpp revision, target `zenzai.gguf` compatibility claim, and a clean baseline of the current patches and receipts.
2. Treat the converter fork/header refresh and the llama.cpp submodule bump as one coupled change: update the fork's shipped headers and `Sources/llama.cpp/module.modulemap` to the same C API/ABI as the newly built `libllama`, then update the submodule pointer and the future converter dependency pin together.
3. Rebase every converter patch against the new source context, never by blind application: revalidate 0001 before backend loading with `pinVulkanICDIfNeeded`, 0003 with `hazkey-community patch`, 0004 with `ZenzInferencePerf`, and 0005 with `llama_memory_seq_pos_max`. Reconfirm the converter build order `0001 -> 0004 -> 0005 -> 0003` and the trait gates for 0001/0004/0005 versus unconditional 0003.
4. Re-run the receipt matrix on disposable trees: the complete converter stack dry-run, the CI-compatible stack dry-run, and meaningful already-applied failure probes. Do not apply patches directly to the real submodule.
5. Run the canonical CMake/Ninja build using the resolved scratch checkout and prove the expected anchors reached that checkout; also run the canonical Swift test path against the built llama libraries.
6. Run seam-benchmark parity with the real model and compare the on/off differential invariants and reported neural share with the prior evidence. Investigate a model-load failure, missing inference seam, or material backend change before accepting the bump.

All five acceptance gates must pass before the future update can be accepted:

1. **OutputParity suite** passes.
2. **Real-model benchmark gate:** `HAZKEY_BENCH=1` `InferenceSeamBenchmarkTests` passes with the real model.
3. **Multi-ICD SIGILL regression gate:** with two or more ICDs installed, 0001 prevents the issue-#29 startup regression.
4. **CPU fallback gate:** a `GGML_VULKAN=OFF` build passes.
5. **Submodule-pointer gate:** the recorded submodule pointer is the reviewed intended revision and the working tree is clean.

Update only in a separately planned delivery after this checklist passes.
