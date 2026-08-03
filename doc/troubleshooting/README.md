[简体中文](./README.zh-CN.md)

# Tim2Tox Troubleshooting Index

This page collects the current troubleshooting entry points for Tim2Tox test failures, native crashes, and environment issues. Historical investigation snapshots and generated validation logs are intentionally not kept as durable docs.

## Where To Start

- **Auto tests fail, hang, or flake**: start with [auto_tests/README.md](../../auto_tests/README.md), then follow its troubleshooting and best-practice sections.
- **Native crash, FFI symbol issue, callback crash, or thread issue**: use [auto_tests/DEBUG_NATIVE_CRASH.md](../../auto_tests/DEBUG_NATIVE_CRASH.md) to capture native stacks with lldb.
- **Virtual-clock behavior differs from wall-clock behavior**: read [auto_tests/VIRTUAL_CLOCK.md](../../auto_tests/VIRTUAL_CLOCK.md) for the test-mode model and common failure patterns.

## Current Entry Points

- [auto_tests/README.md](../../auto_tests/README.md) — test suite hub: running tests, phase coverage, troubleshooting, and best practices.
- [auto_tests/DEBUG_NATIVE_CRASH.md](../../auto_tests/DEBUG_NATIVE_CRASH.md) — lldb workflow for native stacks.
- [auto_tests/VIRTUAL_CLOCK.md](../../auto_tests/VIRTUAL_CLOCK.md) — virtual-clock mode design and authoring guide.
