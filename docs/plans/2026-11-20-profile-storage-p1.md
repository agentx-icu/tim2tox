# Profile storage P1 fixes

**Goal:** Allow protected profiles to initialize offline and retain live queued
sends when a running profile receives its first password.

**Architecture:** Read the identity from a pinned native Tox session, independently
of login/connection callbacks. Track queue entries created by this persistence
session so password enablement transfers only attributable sends to the protected
account path. Publish the destination and switch the active path before cleaning
up the shared source, using the existing mutation fence and atomic file writer.

**Stack:** C++, GoogleTest/CTest, Dart, Flutter test.

## 1. Offline profile identity

- Add an FFI regression in `test/InitSdkProfileAtRestTest.cpp`: open and reopen
  a protected profile, with no login or connection, and read its full identity.
- Run `init_sdk_profile_at_rest_test` and confirm the new test fails.
- Change `V2TIMManagerImpl::GetSelfToxAddress()` to read the pinned live Tox.
- Update the C++/FFI/Dart comments describing identity availability.
- Run the native regression and protected-storage tests.

## 2. Live queue migration

- Extend `dart/test/profile_storage_encryption_test.dart` with default-path
  migration, restart, unrelated legacy queue, and destination failure cases.
- Run the tests against the old implementation and confirm the losses.
- Preserve session ownership across queue item mutations. On the first default
  account binding, merge live entries into the authenticated destination,
  durably write it, then switch the cache/path and remove only those entries
  from the shared source. Preserve source/cache if destination publication fails;
  retain the protected binding if source cleanup fails. Reset attribution when
  the service begins a new profile session.
- Run queue persistence, account rebind and encryption suites.

## 3. Integration and verification

- Exercise real `FfiChatService.init()` against the rebuilt native library before
  login; also exercise live rekey and `waitForProfileStorageMigration()`.
- Build native targets, run CTest, run the Dart suite, and inspect the final diff.
- Report exact passes and distinguish any reproduced baseline failures.
