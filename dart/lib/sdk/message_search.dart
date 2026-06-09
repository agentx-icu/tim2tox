import '../models/chat_message.dart';

/// Control-signal prefixes — messages persisted in history that are NOT
/// user-visible bubbles (revoke / sticker / custom / location / reaction).
/// They must never appear in `searchLocalMessages` results.
const List<String> kSearchControlSignalPrefixes = <String>[
  '__revoke__:',
  '__face__:',
  '__custom__:',
  '__location__:',
  '__reaction__:',
];

/// True if [msg] is a user-visible message eligible for search — i.e. NOT a
/// control-signal carrier. Applied for EVERY local-search mode (keyword,
/// sender-only, time-only), so the keyword filter and the sender filter share
/// the same exclusion.
bool isSearchableMessage(ChatMessage msg) {
  final text = msg.text;
  for (final prefix in kSearchControlSignalPrefixes) {
    if (text.startsWith(prefix)) return false;
  }
  return true;
}

/// Keyword match — the pure core of `Tim2ToxSdkPlatform.searchLocalMessages`
/// (S93). Case-insensitive substring on OWNED payload fields (the bubble `text`
/// plus a file message's `fileName`), NOT UI summary strings.
///
/// [matchAll] true → EVERY keyword must match (V2TIM `searchParam.type == 1`,
/// AND); false → ANY keyword (`type == 0`, OR — the default). Empty/whitespace
/// keywords are ignored; a search with no effective keyword matches nothing.
/// Control-signal messages ([isSearchableMessage]) never match.
bool chatMessageMatchesKeywords(
  ChatMessage msg, {
  required List<String> keywords,
  required bool matchAll,
}) {
  if (!isSearchableMessage(msg)) return false;
  final effective = effectiveKeywords(keywords);
  if (effective.isEmpty) return false;
  final haystack =
      '${msg.text.toLowerCase()}\n${(msg.fileName ?? '').toLowerCase()}';
  bool has(String k) => haystack.contains(k);
  return matchAll ? effective.every(has) : effective.any(has);
}

/// Trim + lower-case the keywords, dropping empty/whitespace-only entries.
List<String> effectiveKeywords(List<String> keywords) => <String>[
      for (final k in keywords)
        if (k.trim().isNotEmpty) k.trim().toLowerCase(),
    ];
