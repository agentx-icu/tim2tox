# Tim2Tox Documentation
> Language: [Chinese](README.md) | [English](README.en.md)

## Recommended reading paths (by role)

- **New readers (understand what Tim2Tox is)**: start with the [Main README](../README.en.md) → then [architecture/ARCHITECTURE.en.md](architecture/ARCHITECTURE.en.md) §1–3 → come back here for deep dives
- **Integrators (integrate into a client)**: start with the [Main README](../README.en.md) ("two integration paths and steps") → then [integration/INTEGRATION_OVERVIEW.en.md](integration/INTEGRATION_OVERVIEW.en.md) (path comparison and five steps) → as needed [architecture/BINARY_REPLACEMENT.en.md](architecture/BINARY_REPLACEMENT.en.md), [architecture/ARCHITECTURE.en.md](architecture/ARCHITECTURE.en.md) §10, [integration/BOOTSTRAP_AND_POLLING.en.md](integration/BOOTSTRAP_AND_POLLING.en.md) → build in [README_BUILD.md](../README_BUILD.md)
- **Maintainers (modify core / extend features)**: [architecture/ARCHITECTURE.en.md](architecture/ARCHITECTURE.en.md) (full) → [architecture/FFI_COMPAT_LAYER.en.md](architecture/FFI_COMPAT_LAYER.en.md), [architecture/BINARY_REPLACEMENT.en.md](architecture/BINARY_REPLACEMENT.en.md) → API & writing standard: [api/API_REFERENCE.en.md](api/API_REFERENCE.en.md), [api/API_REFERENCE_TEMPLATE.en.md](api/API_REFERENCE_TEMPLATE.en.md) → development & rules: [development/DEVELOPMENT_GUIDE.en.md](development/DEVELOPMENT_GUIDE.en.md), [architecture/MODULARIZATION.en.md](architecture/MODULARIZATION.en.md), [development/FFI_FUNCTION_DECLARATION_GUIDE.en.md](development/FFI_FUNCTION_DECLARATION_GUIDE.en.md)

## Build, tests, and troubleshooting entry points

- **Build guide (single source of truth)**: [README_BUILD.md](../README_BUILD.md)
- **Troubleshooting index (entry page)**: [troubleshooting/README.en.md](troubleshooting/README.en.md)
- **Auto tests**: [auto_tests/README.md](../auto_tests/README.md)
- **Native crash troubleshooting**: [auto_tests/DEBUG_NATIVE_CRASH.md](../auto_tests/DEBUG_NATIVE_CRASH.md)
- **Regression baseline**: [auto_tests/VALIDATION_RESULTS.md](../auto_tests/VALIDATION_RESULTS.md) — most recent full-regression pass/fail snapshot

## Maintainer Index

- [architecture/ARCHITECTURE.en.md](architecture/ARCHITECTURE.en.md) - Overall architecture (deep technical reference): layer responsibilities, call chains, FFI/callbacks/dual paths, Bootstrap and polling, risks and testing
- [api/API_REFERENCE.en.md](api/API_REFERENCE.en.md) - V2TIM, FFI and Dart layer API reference (sub-pages: [V2TIM](api/API_REFERENCE_V2TIM.en.md), [FFI](api/API_REFERENCE_FFI.en.md), [Dart](api/API_REFERENCE_DART.en.md))
- [api/API_SUPPORT_MATRIX.en.md](api/API_SUPPORT_MATRIX.en.md) - Per-API real support-status matrix (native / dart-only / local-only / text-degraded / no-op-success / unsupported); read this before integrating to see which APIs actually work
- [api/API_REFERENCE_TEMPLATE.en.md](api/API_REFERENCE_TEMPLATE.en.md) - API reference writing template (entry structure, classification and tagging)
- [development/DEVELOPMENT_GUIDE.en.md](development/DEVELOPMENT_GUIDE.en.md) - Development process, building, testing and debugging advice
- [architecture/MODULARIZATION.en.md](architecture/MODULARIZATION.en.md) - FFI module split structure and module responsibilities

## Integration (single-page entry for integrators)

- [integration/INTEGRATION_OVERVIEW.en.md](integration/INTEGRATION_OVERVIEW.en.md) - Two paths comparison, choice guide, five integration steps, and further reading

## Core Mechanism

- [architecture/BINARY_REPLACEMENT.en.md](architecture/BINARY_REPLACEMENT.en.md) - Dynamic library replacement design and call chain
- [architecture/FFI_COMPAT_LAYER.en.md](architecture/FFI_COMPAT_LAYER.en.md) - Dart* compatibility layer: callbacks, JSON format, implementation status
- [integration/RESTORE_AND_PERSISTENCE.en.md](integration/RESTORE_AND_PERSISTENCE.en.md) - Persistence and recovery workflow
- [integration/TOXAV_AND_SIGNALING.en.md](integration/TOXAV_AND_SIGNALING.en.md) - ToxAV, signaling, TUICallKit, and instance routing
- [integration/BOOTSTRAP_AND_POLLING.en.md](integration/BOOTSTRAP_AND_POLLING.en.md) - Bootstrap node loading, network establishment, and polling loop

## Compatibility and Topics

- [development/MULTI_INSTANCE_SUPPORT.en.md](development/MULTI_INSTANCE_SUPPORT.en.md) - Multiple instance support scenarios and APIs
- [development/FFI_FUNCTION_DECLARATION_GUIDE.en.md](development/FFI_FUNCTION_DECLARATION_GUIDE.en.md) - FFI function declaration rules and self-test checklist
- `isCustomPlatform` routing behavior: see [architecture/BINARY_REPLACEMENT.en.md](architecture/BINARY_REPLACEMENT.en.md) and SDK source; no dedicated troubleshooting page.
- [architecture/PLATFORM_VS_V2TIM_AND_CONVERSATION_LISTENER.en.md](architecture/PLATFORM_VS_V2TIM_AND_CONVERSATION_LISTENER.en.md) - Analysis of the relationship between Platform and V2TIM under binary replacement

## Example client

- [Main README](../README.en.md)
- A client that uses Tim2Tox is [toxee](https://github.com/agentx-icu/toxee). For its documentation and account/session details, see the [toxee repository](https://github.com/agentx-icu/toxee); when Tim2Tox is used as a submodule, the parent repo’s `doc/` may also apply.
