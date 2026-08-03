[简体中文](./README.zh-CN.md)

# Tim2Tox Documentation

## Recommended reading paths (by role)

- **New readers (understand what Tim2Tox is)**: start with the [Main README](../README.md) → then [architecture/ARCHITECTURE.md](architecture/ARCHITECTURE.md) §1–3 → come back here for deep dives
- **Integrators (integrate into a client)**: start with the [Main README](../README.md) ("two integration paths and steps") → then [integration/INTEGRATION_OVERVIEW.md](integration/INTEGRATION_OVERVIEW.md) (path comparison and five steps) → as needed [architecture/BINARY_REPLACEMENT.md](architecture/BINARY_REPLACEMENT.md), [architecture/ARCHITECTURE.md](architecture/ARCHITECTURE.md) §10, [integration/BOOTSTRAP_AND_POLLING.md](integration/BOOTSTRAP_AND_POLLING.md) → build in [README_BUILD.md](../README_BUILD.md)
- **Maintainers (modify core / extend features)**: [architecture/ARCHITECTURE.md](architecture/ARCHITECTURE.md) (full) → [architecture/FFI_COMPAT_LAYER.md](architecture/FFI_COMPAT_LAYER.md), [architecture/BINARY_REPLACEMENT.md](architecture/BINARY_REPLACEMENT.md) → API & writing standard: [api/API_REFERENCE.md](api/API_REFERENCE.md), [api/API_REFERENCE_TEMPLATE.md](api/API_REFERENCE_TEMPLATE.md) → development & rules: [development/DEVELOPMENT_GUIDE.md](development/DEVELOPMENT_GUIDE.md), [architecture/MODULARIZATION.md](architecture/MODULARIZATION.md), [development/FFI_FUNCTION_DECLARATION_GUIDE.md](development/FFI_FUNCTION_DECLARATION_GUIDE.md)

## Build, tests, and troubleshooting entry points

- **Build guide (single source of truth)**: [README_BUILD.md](../README_BUILD.md)
- **Troubleshooting index (entry page)**: [troubleshooting/README.md](troubleshooting/README.md)
- **Auto tests**: [auto_tests/README.md](../auto_tests/README.md)
- **Native crash troubleshooting**: [auto_tests/DEBUG_NATIVE_CRASH.md](../auto_tests/DEBUG_NATIVE_CRASH.md)

## Maintainer Index

- [architecture/ARCHITECTURE.md](architecture/ARCHITECTURE.md) - Overall architecture (deep technical reference): layer responsibilities, call chains, FFI/callbacks/dual paths, Bootstrap and polling, risks and testing
- [api/API_REFERENCE.md](api/API_REFERENCE.md) - V2TIM, FFI and Dart layer API reference (sub-pages: [V2TIM](api/API_REFERENCE_V2TIM.md), [FFI](api/API_REFERENCE_FFI.md), [Dart](api/API_REFERENCE_DART.md))
- [api/API_SUPPORT_MATRIX.md](api/API_SUPPORT_MATRIX.md) - Per-API real support-status matrix (native / dart-only / local-only / text-degraded / no-op-success / unsupported); read this before integrating to see which APIs actually work
- [api/API_REFERENCE_TEMPLATE.md](api/API_REFERENCE_TEMPLATE.md) - API reference writing template (entry structure, classification and tagging)
- [development/DEVELOPMENT_GUIDE.md](development/DEVELOPMENT_GUIDE.md) - Development process, building, testing and debugging advice
- [architecture/MODULARIZATION.md](architecture/MODULARIZATION.md) - FFI module split structure and module responsibilities

## Integration (single-page entry for integrators)

- [integration/INTEGRATION_OVERVIEW.md](integration/INTEGRATION_OVERVIEW.md) - Two paths comparison, choice guide, five integration steps, and further reading

## Core Mechanism

- [architecture/BINARY_REPLACEMENT.md](architecture/BINARY_REPLACEMENT.md) - Dynamic library replacement design and call chain
- [architecture/FFI_COMPAT_LAYER.md](architecture/FFI_COMPAT_LAYER.md) - Dart* compatibility layer: callbacks, JSON format, implementation status
- [integration/RESTORE_AND_PERSISTENCE.md](integration/RESTORE_AND_PERSISTENCE.md) - Persistence and recovery workflow
- [integration/TOXAV_AND_SIGNALING.md](integration/TOXAV_AND_SIGNALING.md) - ToxAV, signaling, TUICallKit, and instance routing
- [integration/BOOTSTRAP_AND_POLLING.md](integration/BOOTSTRAP_AND_POLLING.md) - Bootstrap node loading, network establishment, and polling loop

## Compatibility and Topics

- [development/MULTI_INSTANCE_SUPPORT.md](development/MULTI_INSTANCE_SUPPORT.md) - Multiple instance support scenarios and APIs
- [development/FFI_FUNCTION_DECLARATION_GUIDE.md](development/FFI_FUNCTION_DECLARATION_GUIDE.md) - FFI function declaration rules and self-test checklist
- `isCustomPlatform` routing behavior: see [architecture/BINARY_REPLACEMENT.md](architecture/BINARY_REPLACEMENT.md) and SDK source; no dedicated troubleshooting page.
- [architecture/PLATFORM_VS_V2TIM_AND_CONVERSATION_LISTENER.md](architecture/PLATFORM_VS_V2TIM_AND_CONVERSATION_LISTENER.md) - Analysis of the relationship between Platform and V2TIM under binary replacement

## Example client

- [Main README](../README.md)
- A client that uses Tim2Tox is [toxee](https://github.com/agentx-icu/toxee). For its documentation and account/session details, see the [toxee repository](https://github.com/agentx-icu/toxee); when Tim2Tox is used as a submodule, the parent repo’s `doc/` may also apply.
