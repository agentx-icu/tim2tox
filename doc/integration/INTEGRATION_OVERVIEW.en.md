# Tim2Tox Integration Overview

> Single-page entry for integrators: two paths comparison, choice guide, five integration steps, and further reading. For project positioning and architecture diagram see the [Main README](../../README.en.md).

---

## Two integration paths

| Aspect | Binary replacement | Platform / FfiChatService |
|--------|--------------------|----------------------------|
| **How** | Call `setNativeLibraryName('tim2tox_ffi')` at app startup; SDK loads tim2tox’s native library. Business still uses `TIMManager.instance` etc.; under the hood calls go Dart* → V2TIM. | Set `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(ffiService: ffiChatService)`. When `isCustomPlatform == true`, the SDK routes configured methods to the Platform, implemented by FfiChatService. |
| **Best for** | **Minimal code change**, only swapping the backend to Tox; quick validation or clients that prioritize “compatible with native calls.” | When you need **history, polling, custom callbacks, Bootstrap config, call bridge** implemented on the Dart side; full product clients. |
| **Dart changes** | Only set the library name in main and ensure the FFI library is loadable; no Platform implementation. | Construct FfiChatService, implement injectable interfaces, set the Platform instance. |
| **Capabilities** | Login, send message, friends/groups, etc., in line with native SDK usage. | Same plus history, polling, conversation sync, Bootstrap, calls—where Dart state and persistence are required. |

### Integration path choice

| Your goal | Recommendation |
|-----------|-----------------|
| Minimal change, just verify “Tox works” | Binary replacement: `setNativeLibraryName('tim2tox_ffi')` and ship the FFI library; do not set Platform. |
| Full chat product (history, conversations, Bootstrap, optional calls) | Platform + FfiChatService: implement interfaces, create FfiChatService, register Tim2ToxSdkPlatform; you can keep binary replacement too (hybrid). |
| Hybrid (recommended) | Binary replacement + Tim2ToxSdkPlatform; history, polling, Bootstrap, etc. go through Platform. |

---

## Integrating into a client (five steps)

1. **Dependency**: Add `tim2tox_dart` to the client’s `pubspec.yaml` (path to this repo’s `dart` or a published version).
2. **Binary replacement (optional)**: At the very start of `main()`, call `setNativeLibraryName('tim2tox_ffi')` and ensure the app can load `libtim2tox_ffi` (build output must be in the right place for your project).
3. **Interfaces and FfiChatService**: Implement `ExtendedPreferencesService`, `LoggerService`, `BootstrapService`, etc. (see [`dart/lib/interfaces/`](../../dart/lib/interfaces/) and [API_REFERENCE_DART.en.md](../api/API_REFERENCE_DART.en.md)), construct `FfiChatService`, and `await ffiService.init()`.
4. **Platform (if used)**: `TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(ffiService: ffiService, ...)`.
5. **UIKit**: Use Tencent Cloud Chat UIKit as usual; login, send message, conversation list, etc. will go through Tim2Tox to Tox.

**Reference implementation**: A client that uses Tim2Tox is [toxee](https://github.com/anonymoussoft/toxee); for hybrid setup, interface implementations, Bootstrap, history, see [toxee’s documentation](https://github.com/anonymoussoft/toxee).

---

## Further reading

- [BINARY_REPLACEMENT.en.md](../architecture/BINARY_REPLACEMENT.en.md) — Binary replacement design and call chain
- [API_REFERENCE_DART.en.md](../api/API_REFERENCE_DART.en.md) — Dart package API (FfiChatService / Tim2ToxSdkPlatform / interfaces)
- [BOOTSTRAP_AND_POLLING.en.md](BOOTSTRAP_AND_POLLING.en.md) — Bootstrap nodes and polling (if doing network/startup config)
- [ARCHITECTURE.en.md](../architecture/ARCHITECTURE.en.md) §10 — Relationship with the integrating client
- [README_BUILD.en.md](../../README_BUILD.en.md) — Build outputs and scripts
