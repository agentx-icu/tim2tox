# Dart file and avatar contract repair

**Goal:** Repair the three existing full-suite failures without reverting the
native transfer lifecycle fixes that made their source assertions obsolete.

## Root cause

All three failures reproduce on merged master `ab4b995`. Commit `ff97979`
introduced `SendFile` and `DispatchFileOffer` to serialize offer publication with
its owned context, and added tracked-send failure notification and context cleanup
on successful cancellation. The Dart contracts predate that change:

- The avatar contract expects `tox_file_send` in the public avatar wrapper,
  although that wrapper passes its digest/name to `DispatchFileOffer`.
- The generic-file contract checks only the thin public wrapper, although
  `SendFile` chooses DATA/null file ID for both legacy and tracked entry points.
- The receive-control contract globally prohibits `EraseSendContext`, although
  successful cancellation must release tracked sends. Resume/pause/failure must
  still retain their contexts, and a failed receive resume must roll back.

The native implementation and its existing C++ source regressions agree on these
contracts. The fix belongs in the stale Dart assertions, not in native behavior.

## Implementation and verification

1. Keep the observed three failures as the red baseline.
2. Update `dart/test/qtox_avatar_wire_contract_test.dart` to trace the wrapper,
   `SendFile`, and dispatcher edges. Preserve raw digest, lowercase filename,
   DATA/AVATAR kind, size, filename, and owned-context assertions.
3. Scope `dart/test/file_control_contract_test.dart` cleanup checks to successful
   cancellation and require tracked failure notification before context removal.
   Retain the existing receive-open ordering and rollback assertions.
4. Include both contract files in formatting, analysis, and test CI steps.
5. Run the targeted suite, then temporarily mutate native source to demonstrate
   that the updated tests reject wrong file kinds, lost metadata, and missing or
   premature cancellation cleanup. Restore native source after each check.
6. Run full Dart tests with the real native storage lifecycle tests enabled,
   CTest, static analysis, and diff checks. Review, commit, push, and open a PR
   documenting the root cause and exact results.

## Verified results

- Before repair: the two targeted files reproduced the same three failures
  (14 passed, 3 failed). After repair: 18 passed, including the new dispatcher
  forwarding contract.
- Four temporary native-source mutations all failed the intended contracts:
  wrong caller kinds/avatar ID, dropped dispatcher metadata, missing CANCEL
  cleanup, and premature RESUME cleanup. Native source was restored unchanged.
- Full Dart suite with the real native library: 287 passed, 2 existing skips,
  zero failures. All three protected-profile lifecycle tests ran.
- Native CTest: 137 passed, 1 disabled. Workflow formatting and analysis passed;
  `actionlint` and `git diff --check` passed.
