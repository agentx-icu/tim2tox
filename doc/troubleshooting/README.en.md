# Tim2Tox Troubleshooting & Historical Investigations Index

This page consolidates Tim2Tox troubleshooting entry points, test-failure navigation, and historical investigation notes, keeping them separate from the main architecture/integration docs.

## Where to start

- **I'm running the auto tests and something fails / hangs / flakes**: start with [auto_tests/README.md](../../auto_tests/README.md), then follow the "troubleshooting / best practices" sections there. The most recent regression baseline lives at [auto_tests/VALIDATION_RESULTS.md](../../auto_tests/VALIDATION_RESULTS.md).
- **I hit a native crash (FFI, symbols, callbacks, threading)**: use [auto_tests/DEBUG_NATIVE_CRASH.md](../../auto_tests/DEBUG_NATIVE_CRASH.md) to capture native stacks via lldb; common symptoms are listed in `auto_tests/README.md`'s troubleshooting section.
- **I want mechanism-level analysis of a past issue**: see "Historical investigations" below (not guaranteed to match current versions).

## Test & troubleshooting docs (recommended entry points)

- [auto_tests/README.md](../../auto_tests/README.md) — test suite hub (how to run, coverage, troubleshooting)
- [auto_tests/VALIDATION_RESULTS.md](../../auto_tests/VALIDATION_RESULTS.md) — latest full-regression pass/fail snapshot
- [auto_tests/DEBUG_NATIVE_CRASH.md](../../auto_tests/DEBUG_NATIVE_CRASH.md) — inspect native stacks via lldb