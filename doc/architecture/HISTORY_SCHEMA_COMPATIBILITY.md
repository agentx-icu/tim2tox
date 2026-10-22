[简体中文](HISTORY_SCHEMA_COMPATIBILITY.zh-CN.md)

# History schema compatibility

A history document with `version` greater than this library's supported version
requires an updated application. It stays at its original path, with its original
bytes. It is not corruption and is never quarantined or interpreted as an empty
conversation.

The per-conversation operation fence checks primary and backup schemas before
loading, writing, clearing or accessing the archive. Bulk loading propagates
`HistorySchemaNewerThanAppException`, including through `FfiChatService` startup,
so the integrating application can show an upgrade message. Directory merges also
check their inputs before applying any recovery or rewriting a destination.

A save without a preceding load is checked too. Unsupported-version failures are
not retried; ordinary disk failures retain the existing bounded retry and failure
notification behavior. Explicit whole-store/account deletion remains a separate
user-authorized destructive operation.

Regression tests: `dart/test/history_schema_downgrade_test.dart`, plus the
integrator's history concurrency and load-resilience suites. The policy is shared
Dart and covers all desktop and mobile hosts. It does not replace store ownership
or protect against an unrelated process modifying a file concurrently.

The `History persistence` GitHub Actions workflow runs the schema regression,
write-failure signaling, offline queue and failed-message persistence suites on
pull requests and master pushes. It uses a clean library checkout and public
Dart dependencies; neither integrator overrides nor a native FFI binary are
required. Formatting and analysis cover the schema guard and its regression
file. This storage gate does not certify SDK/native or installed-app behavior.
