/// Tox identifier helpers shared by the Dart-side platform / service code.
///
/// Tox public keys are 64 hex chars; full Tox IDs are 76 hex chars
/// (64 pubkey + 8 nospam + 4 checksum). Most identity-routing call
/// sites need the 64-char public-key form regardless of which they
/// were handed. Historically each call site reimplemented its own
/// ad-hoc `length > 64 ? substring(0, 64) : id` snippet; this helper
/// is the single canonical version.
///
/// Behaviour (never throws — callers depend on this for safety):
///   * Trim whitespace, lowercase (hex is case-insensitive).
///   * 76 chars → first 64 (public key part of a Tox ID).
///   * 64 chars → returned as-is (already a public key).
///   * Anything else → returned cleaned (lowercased + trimmed) so
///     non-hex placeholders, group IDs, and short test fixtures still
///     round-trip through this helper.
String toToxPublicKey(String input) {
  final cleaned = input.trim().toLowerCase();
  if (cleaned.length == 76) return cleaned.substring(0, 64);
  if (cleaned.length > 64) return cleaned.substring(0, 64);
  return cleaned;
}
