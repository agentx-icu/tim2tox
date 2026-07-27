/// A durable draft for one SDK conversation.
class ConversationDraft {
  const ConversationDraft({
    required this.conversationID,
    required this.text,
    required this.timestamp,
  });

  /// SDK conversation ID (`c2c_...` or `group_...`).
  final String conversationID;

  /// Draft composer contents. Persisted drafts are always non-empty.
  final String text;

  /// Last edit time in Unix seconds, matching `V2TimConversation`.
  final int timestamp;
}

/// Optional durable storage capability for conversation drafts.
///
/// [accountToxId] is always the canonical full 76-character Tox address. An
/// implementation must scope every read and write by the complete value; a
/// shortened account prefix is not a valid storage key.
abstract interface class DraftPreferencesService {
  Future<ConversationDraft?> loadConversationDraft({
    required String accountToxId,
    required String conversationID,
  });

  Future<void> saveConversationDraft({
    required String accountToxId,
    required ConversationDraft draft,
  });

  Future<void> removeConversationDraft({
    required String accountToxId,
    required String conversationID,
  });
}
