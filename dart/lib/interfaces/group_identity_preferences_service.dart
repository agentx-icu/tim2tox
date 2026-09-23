/// Optional durable storage for a group's kind, next to its chat id.
///
/// The native layer reports a group's stable identity (NGC chat id or legacy
/// conference id) through [ExtendedPreferencesService.setGroupChatId] and its
/// kind (`group`, `conference`, `av_conference`, ...) through [setGroupType]
/// as soon as it learns them. After a restart both are replayed to native so
/// every group is rebound by identity, and a conference is never treated as
/// an NGC group (or the reverse) because its kind was forgotten.
abstract interface class GroupIdentityPreferencesService {
  Future<String?> getGroupType(String groupId);

  Future<void> setGroupType(String groupId, String groupType);

  /// Forget everything that ties [groupId] to a Tox group: chat id,
  /// conference id and kind. Called when the user leaves or dismisses it.
  Future<void> removeGroupIdentity(String groupId);
}

/// Optional: maps a Tim2Tox-owned preference key into the current account's
/// namespace. The generic `getString` / `setString` / `getStringSet` calls
/// take keys verbatim, so keys Tim2Tox invents itself (pending group invites,
/// groups whose history is kept, invites queued for offline friends) must be
/// scoped explicitly or one account's data is read by the next.
abstract interface class AccountScopedPreferencesService {
  String accountScopedKey(String key);
}
