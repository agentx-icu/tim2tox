/// Unified message history persistence service
///
/// This service provides a unified interface for persisting message history
/// that can be used by both Platform interface scheme and binary replacement scheme.
///
/// Storage location: `<appDir>/chat_history/<conversationId>.json`
/// Data format: JSON with conversationId and messages array
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../interfaces/logger_service.dart';
import '../models/chat_message.dart';
import 'conversation_id_utils.dart';

/// Message history persistence service
///
/// Provides unified message history persistence for both Platform and binary replacement schemes.
/// When [historyDirectory] is set (e.g. per-account path from app), uses that directory; otherwise
/// uses app support dir with optional instanceId for multi-instance.
///
/// NOTE (M3): Messages are persisted as plaintext JSON. At-rest encryption
/// (e.g. AES-GCM keyed off the Tox profile password or OS keychain/keystore)
/// is a known gap and tracked separately. Do not add new sensitive fields
/// here without revisiting that limitation.
class MessageHistoryPersistence {
  final int? _instanceId;

  /// Per-account directory this store writes to, when one was injected.
  ///
  /// Not `final`: a host that cannot know the account until after the Tox
  /// profile is open re-points it exactly once through
  /// [rebindHistoryDirectory], in the pre-boot window. Every read of it goes
  /// through [_getHistoryDirectory].
  String? _historyDirectory;
  final LoggerService? _logger;

  /// Replaces `getApplicationSupportDirectory()` as the parent of the default
  /// (non-injected) history directory. For tests and hosts without
  /// path_provider; has no effect when [historyDirectory] is injected.
  final String? _appSupportRootOverride;

  MessageHistoryPersistence({
    int? instanceId,
    String? historyDirectory,
    LoggerService? logger,
    String? appSupportRootOverride,
  })  : _instanceId = instanceId,
        _historyDirectory = historyDirectory,
        _logger = logger,
        _appSupportRootOverride = appSupportRootOverride {
    // X11 from `local-storage-review-2026-05-18.md`:
    // when no explicit per-account [historyDirectory] is injected we fall
    // back to a single shared `<AppSupport>/chat_history` (or
    // instance-scoped) directory. With more than one account on the device
    // that silently merges histories — conversation files key on peer
    // pubkey only, so messages from two different accounts to the same
    // peer collide. Surface the issue at construction time so integrators
    // notice early. Once the owning identity is known ([openSession] with
    // an `ownerKey`, which FfiChatService does before loading), the default
    // directory is owner-bound: see [_resolveOwnedDirectory].
    if (historyDirectory == null || historyDirectory.isEmpty) {
      const warning =
          '[MessageHistoryPersistence] no historyDirectory injected — '
          'falling back to shared <AppSupport>/chat_history. '
          'For multi-account isolation, callers should inject a '
          'per-account historyDirectory (e.g. AppPaths.getAccountChatHistoryPath(toxId)).';
      final logger = _logger;
      if (logger != null) {
        logger.logWarning(warning);
      } else {
        // No logger available — last resort so the warning still surfaces
        // in dev consoles and test output without requiring the caller to
        // wire one up.
        // ignore: avoid_print
        stderr.writeln(warning);
      }
    }
  }

  // In-memory cache: conversationId -> List<ChatMessage>
  final Map<String, List<ChatMessage>> _historyById = {};

  /// Ids removed from the cache whose removal may not be on disk yet
  /// (conversation -> id -> delete sequence). A load that merges the file
  /// back in must not resurrect them; the entries clear once a save that
  /// started after the delete has landed.
  ///
  /// Clearing on save is safe because loads and saves of one conversation
  /// run under the same per-conversation lock ([_serialized]): a load reads
  /// the file and installs it with no write landing in between, so it can
  /// never install pre-delete content after the tombstone is gone.
  final Map<String, Map<String, int>> _recentlyDeleted = {};
  int _deleteSeq = 0;

  // ---- One concurrency model per conversation -----------------------------
  //
  // * Every disk operation on a conversation — save, load, archive read /
  //   rewrite / drain, clear — runs through [_serialized], a FIFO lock keyed
  //   by the normalized id. Appends stay cheap: they mutate the cache
  //   synchronously and only the debounced save takes the lock.
  // * Every operation captures a [_OpToken] SYNCHRONOUSLY when it is called
  //   (epoch + the conversation's generation). [clearHistory] bumps the
  //   conversation generation; [clearAllHistories] and [dispose] bump the
  //   epoch. Work whose token went stale while it waited does not write and
  //   does not install anything into the cache: it belongs to state that was
  //   deliberately discarded.
  // * [clearAllHistories] additionally raises [_clearAllBarrier]: operations
  //   queued after it wait until the directory delete has finished, so a
  //   post-clear write is never deleted and a pre-clear one never survives.
  int _epoch = 0;
  final Map<String, int> _conversationGen = {};
  Future<void>? _clearAllBarrier;

  _OpToken _token(String normalizedId) =>
      (epoch: _epoch, gen: _conversationGen[normalizedId] ?? 0);

  bool _isStale(String normalizedId, _OpToken token) =>
      token.epoch != _epoch ||
      token.gen != (_conversationGen[normalizedId] ?? 0);

  /// Runs [body] after every operation previously queued for [normalizedId]
  /// (and after an in-progress [clearAllHistories]). The slot is claimed
  /// synchronously, before any await, so callers racing on the same tick
  /// still serialize in call order.
  Future<T> _serialized<T>(String normalizedId, Future<T> Function() body) async {
    final prev = _writeFences[normalizedId] ?? Future<void>.value();
    final barrier = _clearAllBarrier;
    final completer = Completer<void>();
    _writeFences[normalizedId] = completer.future;
    try {
      try {
        await prev;
      } catch (_) {
        // Fences complete normally; defensive only.
      }
      if (barrier != null) await barrier;
      return await body();
    } finally {
      // The fence only SERIALIZES (the next operation ignores this one's
      // outcome), so it always completes normally: an errored fence nobody
      // happens to await would surface as an unhandled async error.
      completer.complete();
      if (identical(_writeFences[normalizedId], completer.future)) {
        _writeFences.remove(normalizedId); // ignore: unawaited_futures
      }
    }
  }

  void _clearTombstonesUpTo(String id, int seq) {
    final tombstones = _recentlyDeleted[id];
    if (tombstones == null) return;
    tombstones.removeWhere((_, s) => s <= seq);
    if (tombstones.isEmpty) _recentlyDeleted.remove(id);
  }

  /// Record rows that were just removed from [conversationId]'s cache.
  void noteRemovedFromCache(
      String conversationId, Iterable<ChatMessage> rows) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final seq = ++_deleteSeq;
    final ids = _recentlyDeleted.putIfAbsent(normalizedId, () => {});
    for (final row in rows) {
      if (row.msgID != null) ids[row.msgID!] = seq;
      for (final alias in row.altMsgIds) {
        ids[alias] = seq;
      }
    }
  }

  // In-memory cache: conversationId -> lastViewTimestamp (milliseconds since epoch)
  final Map<String, int> _lastViewTimestampById = {};

  // Maximum number of messages to keep in memory per conversation
  static const int _maxMessagesInMemory = 1000;

  /// On-disk format written by [saveHistory] (`version` key).
  static const int _historyFormatVersion = 2;

  /// Rows pushed out of the in-memory window that are not yet durable in the
  /// conversation's archive file. [saveHistory] drains this BEFORE it rewrites
  /// the main file, inside the same write fence. Invariant: the main file is
  /// never replaced by a truncated list while the rows it dropped exist
  /// nowhere else on disk. A failed archive append leaves the rows here (and
  /// aborts that main-file write), so the next save retries.
  final Map<String, List<ChatMessage>> _pendingArchive = {};

  /// Parsed archive of the most recently read conversation (one entry: the
  /// archive is only consulted while the user scrolls far back in ONE chat).
  String? _archiveCacheId;
  List<ChatMessage>? _archiveCacheRows;

  // Concurrency control: the tail of each conversation's operation queue (see
  // [_serialized]). Each operation chains synchronously onto the previous
  // future before any await — this guarantees strict serialization even when
  // many callers race (the old `while (_writeLocks[id] != null) await ...`
  // pattern let multiple waiters resume on the same microtask tick and
  // bypass the gate).
  final Map<String, Future<void>> _writeFences = {};

  /// P2 debounce state (see `local-storage-review-2026-05-18.md`).
  ///
  /// `appendHistory` used to call `saveHistory` on every single message,
  /// which re-serialized the entire in-memory list to disk per send. Hot
  /// senders (paste, image batch, rapid replies) produced O(messages²) write
  /// volume.
  ///
  /// We now coalesce successive appends to the same conversation into a
  /// single disk write 200ms after the last append. The returned Future from
  /// `appendHistory` still completes when the debounced save lands, so
  /// callers that await it (e.g. `BinaryReplacementHistoryHook.saveMessage`)
  /// still see write failures.
  static const Duration _appendDebounce = Duration(milliseconds: 200);

  /// Upper bound on how long a conversation may stay unsaved while appends
  /// keep arriving. The debounce is trailing: without a cap, a group that
  /// never goes quiet for 200 ms (join chatter, a flood) is never written,
  /// and a mobile swipe-kill loses the whole burst.
  static const Duration _appendMaxWait = Duration(seconds: 2);
  final Map<String, DateTime> _appendFirstDirtyAt = {};
  final Map<String, Timer> _appendDebounceTimers = {};
  final Map<String, Completer<void>> _appendDebouncePending = {};

  /// GH-7 failed-write retry state (see [_armSaveRetry]).
  static const int _maxSaveRetries = 5;
  static const Duration _saveRetryBaseDelay = Duration(seconds: 1);
  final Map<String, int> _saveRetryAttempts = {};
  final Map<String, Timer> _saveRetryTimers = {};

  // M1: conversations that need a post-load normalization save. Collected by
  // [loadHistory] and drained serially by [flushDirtyAfterLoad] from the end
  // of [loadAllHistories], so cold start doesn't fan out N parallel saves.
  final Set<String> _dirtyAfterLoad = {};

  bool _disposed = false;

  /// Identity (64-hex Tox public key) this store belongs to, when the host
  /// told us via [openSession]. Only consulted for the DEFAULT directory.
  String? _ownerKey;

  /// The owner-bound default directory, once resolved for [_ownerKey].
  String? _resolvedDefaultDirPath;

  /// Marker recording which identity a default history directory belongs to.
  /// Not `*.json` / `.tmp` / `.bak`, so no load or cleanup pass touches it.
  static const String _ownerMarkerName = '.tim2tox_history_owner';

  /// Identity the HOST has proven owns an UNMARKED default directory.
  ///
  /// Ownership of a directory that predates owner binding cannot be decided
  /// here — the rows in it carry peer ids, not ours. Only the integrator can
  /// prove it (toxee: `LegacyAccountDataClaim`, via a recorded claim, the
  /// legacy profile's embedded Tox ID, or byte-identity with the account's own
  /// profile). Until one identity is declared here, such a directory is used by
  /// NOBODY: every owner-bound session gets its own isolated directory instead,
  /// and the legacy rows are left exactly where they are. See
  /// [declareProvenDefaultOwner] and [_resolveOwnedDirectory].
  String? _provenDefaultOwner;

  /// Declare, out of band, that [ownerKey] is the proven owner of an unmarked
  /// default history directory, so this store may ADOPT it in place (claiming
  /// it with an owner marker) instead of starting empty beside it.
  ///
  /// For integrators that migrate the legacy data by copying it into a
  /// per-account directory (what toxee does) this is unnecessary — they inject
  /// that directory and the default resolution never runs. It exists for hosts
  /// that keep using the default directory and can prove who owns it.
  ///
  /// Declare it BEFORE [openSession] / the first read: it only changes where
  /// the default directory resolves to, and rows already read from (or written
  /// to) the isolated directory are not moved.
  ///
  /// Passing null (or an unusable key) withdraws the declaration. Never makes
  /// a directory SHARED: at most one identity can be declared, and any other
  /// identity still routes to its own directory.
  void declareProvenDefaultOwner(String? ownerKey) {
    final normalized = _normalizeOwnerKey(ownerKey);
    if (normalized == _provenDefaultOwner) return;
    _provenDefaultOwner = normalized;
    // The proof changes where the default resolves to; drop the memo.
    _resolvedDefaultDirPath = null;
  }

  /// Start (or restart) a session on this store.
  ///
  /// Restores the operational state [dispose] switched off, so a host that
  /// re-inits the same service object after a logout gets working debounce
  /// and retry again (GH #23: `_disposed` used to be permanent and new appends
  /// silently lost their retry). [ownerKey] — the account's Tox public key or
  /// full address — binds the DEFAULT directory to that identity; see
  /// [_resolveOwnedDirectory]. An injected `historyDirectory` is already
  /// per-account and ignores it. A different owner than the previous session
  /// drops all in-memory state first: nothing of one account may be served
  /// to, or written under, another.
  ///
  /// A NULL / unusable [ownerKey] means "this session's identity is not known
  /// yet", and it CLEARS the previous session's owner. It used to keep it,
  /// which is a cross-account read: the host calls this from service init,
  /// before `login()` can reveal the Tox ID, so a store whose previous session
  /// belonged to account A stayed pointed at A's owner-bound default directory
  /// and loaded A's history into B's session. With the owner unknown the
  /// default directory is only used while nothing claims it — see
  /// [_resolveUnownedDirectory].
  void openSession({String? ownerKey}) {
    final normalizedOwner = _normalizeOwnerKey(ownerKey);
    if (normalizedOwner != _ownerKey) {
      if (_ownerKey != null) _resetSessionState();
      _ownerKey = normalizedOwner;
      _resolvedDefaultDirPath = null;
    }
    _disposed = false;
  }

  /// Re-point this store at a per-account [historyDirectory] after
  /// construction, for hosts that only learn the account identity once the
  /// Tox profile is open (toxee's legacy login paths: the service must exist
  /// before `init()` + `login()` can reveal the Tox ID).
  ///
  /// This is a PRE-BOOT operation. It is safe only while the host owns the
  /// store exclusively — before polling starts and before the app has read or
  /// written any history of its own. [FfiChatService.installAccountStorage] is
  /// the supported caller and enforces that window; calling this directly from
  /// a running session is a bug.
  ///
  /// What it guarantees:
  ///  * nothing still owed to the OLD location is dropped — every debounced /
  ///    retrying write is flushed first, and a flush failure aborts the rebind
  ///    (throwing [HistoryFlushException]) rather than discarding those rows;
  ///  * no state read from the old location leaks into the new one — all
  ///    in-memory caches, tombstones, pending archive rows and read barriers
  ///    are dropped, and in-flight work is invalidated via the epoch bump;
  ///  * the owner binding set by [openSession] survives. It only ever governed
  ///    the DEFAULT directory, which an injected directory supersedes, and the
  ///    identity itself has not changed.
  ///
  /// Idempotent: rebinding to the directory already in use is a no-op.
  Future<void> rebindHistoryDirectory(String historyDirectory) async {
    if (historyDirectory.isEmpty) {
      throw ArgumentError.value(
        historyDirectory,
        'historyDirectory',
        'must be a non-empty absolute directory path',
      );
    }
    if (!p.isAbsolute(historyDirectory)) {
      throw ArgumentError.value(
        historyDirectory,
        'historyDirectory',
        'must be absolute; a relative history directory resolves against the '
            'process working directory, which is not the app sandbox',
      );
    }
    final current = _historyDirectory;
    if (current != null &&
        current.isNotEmpty &&
        p.canonicalize(current) == p.canonicalize(historyDirectory)) {
      return;
    }
    try {
      await flushPendingSaves();
    } on HistoryFlushException catch (e, st) {
      // Refuse rather than drain-and-drop: the rows below are about to be
      // cleared from memory, so continuing here would silently lose them.
      _logger?.logError(
        '[MessageHistoryPersistence] rebindHistoryDirectory refused: '
        '${e.conversationIds.length} conversation(s) still owe a write to the '
        'previous location',
        e,
        st,
      );
      rethrow;
    }
    _resetSessionState();
    _historyDirectory = historyDirectory;
    // The owner-bound default no longer applies; drop the memo so a later
    // fallback (should the injected directory ever be cleared) re-resolves.
    _resolvedDefaultDirPath = null;
    _disposed = false;
  }

  static String? _normalizeOwnerKey(String? key) {
    if (key == null) return null;
    final trimmed = key.trim();
    if (trimmed.length < 64) return null;
    final pk = trimmed.substring(0, 64);
    return RegExp(r'^[0-9A-Fa-f]{64}$').hasMatch(pk) ? pk.toUpperCase() : null;
  }

  /// Get the directory for storing message history.
  /// When _historyDirectory is set, uses it (per-account); otherwise uses appDir + instance suffix,
  /// owner-bound once [openSession] supplied the identity.
  Future<Directory> _getHistoryDirectory() async {
    if (_historyDirectory != null && _historyDirectory!.isNotEmpty) {
      final historyDir = Directory(_historyDirectory!);
      if (!await historyDir.exists()) {
        await historyDir.create(recursive: true);
      }
      return historyDir;
    }
    final resolved = _resolvedDefaultDirPath;
    if (resolved != null) {
      final dir = Directory(resolved);
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    final appRoot =
        _appSupportRootOverride ?? (await getApplicationSupportDirectory()).path;
    final basePath = _instanceId != null && _instanceId != 0
        ? '$appRoot/chat_history_instance_$_instanceId'
        : '$appRoot/chat_history';
    final owner = _ownerKey;
    if (owner == null) {
      final path = await _resolveUnownedDirectory(basePath);
      if (_ownerKey == null) _resolvedDefaultDirPath = path;
      return Directory(path);
    }
    final path = await _resolveOwnedDirectory(basePath, owner);
    // Only cache if the owner did not change while we resolved.
    if (_ownerKey == owner) _resolvedDefaultDirPath = path;
    return Directory(path);
  }

  /// The default directory for a session whose owning identity is NOT known.
  ///
  /// A base directory carrying an owner marker belongs to one identity, and a
  /// session that cannot prove it is that identity must neither read nor write
  /// it (that is how account A's history used to land in account B's session:
  /// see [openSession]). Such a session gets its own `<base>_unowned`
  /// directory instead; the rows it writes there are pre-login strays, and the
  /// moment the identity is known [openSession] re-resolves to the account's
  /// own directory.
  ///
  /// An UNMARKED base directory is still used as is, and deliberately so: with
  /// no owner there is nothing to isolate BY, and it is the only shape a host
  /// that never supplies an owner ever produces — isolating it would strand
  /// that host's entire history (and, in toxee, the rows written in the window
  /// between login and `installAccountStorage`, which its migration adopts from
  /// exactly this directory). An identity that IS known never shares an
  /// unproven directory — see [_resolveOwnedDirectory]; that is where the
  /// cross-account read is cut off, because only there is there something to
  /// tell two sessions apart.
  Future<String> _resolveUnownedDirectory(String basePath) async {
    try {
      final marker = File(p.join(basePath, _ownerMarkerName));
      if (await marker.exists()) {
        _logger?.logWarning(
          '[MessageHistoryPersistence] the default history directory is '
          'claimed by an identity and this session has none yet; using an '
          'isolated directory rather than another account\'s history',
        );
        final isolatedPath = '${basePath}_unowned';
        final isolated = Directory(isolatedPath);
        if (!await isolated.exists()) await isolated.create(recursive: true);
        return isolatedPath;
      }
    } catch (e, st) {
      _logger?.logError(
          '[MessageHistoryPersistence] owner marker check failed', e, st);
    }
    final historyDir = Directory(basePath);
    if (!await historyDir.exists()) {
      await historyDir.create(recursive: true);
    }
    return basePath;
  }

  /// Pre-#4: the default directory used to be shared by every account on the
  /// device (files key on the PEER, so two accounts talking to the same peer
  /// read and overwrote one file). With the owner known:
  ///  * a directory marked for this owner is used as is;
  ///  * a directory that is empty (fresh install) is claimed with a marker;
  ///  * a directory marked for ANOTHER owner is never touched — this owner
  ///    gets its own `<base>_<publicKey>` directory;
  ///  * an UNMARKED directory that already holds history predates owner
  ///    binding. Whose it is cannot be proven here (rows carry peer ids, not
  ///    ours), and first-to-ask is not proof: it used to be handed to whichever
  ///    account asked first, which is the SAME bug one layer down — two
  ///    accounts read and overwrote the same per-peer files. It is now given to
  ///    nobody unless the integrator has proven an owner
  ///    ([declareProvenDefaultOwner]; toxee proves it with
  ///    LegacyAccountDataClaim and migrates the rows into a per-account
  ///    directory instead). Every other identity gets its own
  ///    `<base>_<publicKey>` directory and the legacy rows are left untouched,
  ///    so the rightful owner can still claim them later.
  Future<String> _resolveOwnedDirectory(String basePath, String owner) async {
    final base = Directory(basePath);
    final marker = File(p.join(basePath, _ownerMarkerName));
    try {
      if (await marker.exists()) {
        if ((await marker.readAsString()).trim().toUpperCase() == owner) {
          return basePath;
        }
      } else if (!await _holdsHistory(base)) {
        await base.create(recursive: true);
        await marker.writeAsString(owner, flush: true);
        return basePath;
      } else if (_provenDefaultOwner == owner) {
        // The host proved this identity owns the pre-binding directory. Adopt
        // it in place and mark it, so the next account is isolated by the
        // marker check above rather than by this declaration.
        await marker.writeAsString(owner, flush: true);
        return basePath;
      } else {
        _logger?.logWarning(
          '[MessageHistoryPersistence] default history directory predates '
          'owner binding and is not provably this account\'s; leaving it '
          'untouched and using an isolated directory (inject a per-account '
          'historyDirectory, or declare a proven owner, to adopt it)',
        );
        // Falls through to the isolated directory below: an unproven
        // directory is never shared.
      }
    } catch (e, st) {
      _logger?.logError(
          '[MessageHistoryPersistence] owner marker check failed', e, st);
    }
    final isolatedPath = '${basePath}_$owner';
    final isolated = Directory(isolatedPath);
    if (!await isolated.exists()) await isolated.create(recursive: true);
    final isolatedMarker = File(p.join(isolatedPath, _ownerMarkerName));
    if (!await isolatedMarker.exists()) {
      try {
        await isolatedMarker.writeAsString(owner, flush: true);
      } catch (_) {
        // The name already isolates it; the marker is informational here.
      }
    }
    return isolatedPath;
  }

  static Future<bool> _holdsHistory(Directory dir) async {
    if (!await dir.exists()) return false;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (path.endsWith('.json') ||
          path.endsWith('.archive.jsonl') ||
          path.endsWith('.json.bak')) {
        return true;
      }
    }
    return false;
  }

  /// Get the file path for a conversation's history
  ///
  /// Uses ConversationIdUtils to normalize and sanitize the ID for consistent file naming.
  Future<File> _getHistoryFile(String id) async {
    final dir = await _getHistoryDirectory();
    // Normalize and sanitize id for filename
    final normalizedId = ConversationIdUtils.normalize(id);
    final safeId = ConversationIdUtils.sanitizeForFilename(normalizedId);
    final filePath = '${dir.path}/$safeId.json';
    return File(filePath);
  }

  /// Append-only overflow store for rows older than the in-memory window:
  /// one JSON object per line. Deliberately NOT `*.json`, so
  /// [loadAllHistories] never mistakes it for a conversation file.
  Future<File> _getArchiveFile(String id) async {
    final file = await _getHistoryFile(id);
    final path = file.path;
    return File('${path.substring(0, path.length - '.json'.length)}.archive.jsonl');
  }

  /// Get backup file path for a conversation's history
  Future<File> _getBackupFile(String id) async {
    final file = await _getHistoryFile(id);
    return File('${file.path}.bak');
  }

  /// Cached per-process storage-root lookup so we don't hit
  /// path_provider on every load/save.
  ({
    String? appSupport,
    String? documents,
    String? userDownloads
  })? _storageRootsCache;

  /// P1-15 helper. Resolves and caches the storage roots we relativize
  /// against:
  ///   - AppSupport (where file_recv lives)
  ///   - Documents (where Downloads lives on some desktop platforms)
  ///   - userDownloads (R-5: the OS-level user Downloads dir, e.g. ~/Downloads
  ///     on macOS — this is *not* under Documents).
  /// Returns null parts when the platform does not expose the corresponding
  /// directory.
  Future<({String? appSupport, String? documents, String? userDownloads})>
      _resolveStorageRoots() async {
    if (_storageRootsCache != null) return _storageRootsCache!;
    String? appSupport;
    String? documents;
    String? userDownloads;
    try {
      final dir = await getApplicationSupportDirectory();
      appSupport = dir.path;
    } catch (_) {
      // Some platforms (tests) may not have AppSupport.
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      documents = dir.path;
    } catch (_) {
      // Best-effort.
    }
    try {
      // R-5: macOS' ~/Downloads (and the analogous user-level Downloads
      // dir on other platforms) is the real default landing spot for
      // received files but lives outside the Documents tree, so the old
      // {{downloads}} placeholder only matched a niche `documents/Downloads/`
      // subdir. Add a dedicated placeholder so cross-device / reinstall
      // history continues to resolve.
      final dir = await getDownloadsDirectory();
      if (dir != null) {
        userDownloads = dir.path;
      }
    } catch (_) {
      // Best-effort; getDownloadsDirectory is not implemented everywhere.
    }
    final roots = (
      appSupport: appSupport,
      documents: documents,
      userDownloads: userDownloads,
    );
    _storageRootsCache = roots;
    return roots;
  }

  /// P1-15: rewrite an absolute path under a well-known root to a
  /// placeholder token. Unknown paths are returned unchanged so legacy
  /// rows continue to round-trip.
  String _relativizePath(String absolutePath,
      ({String? appSupport, String? documents, String? userDownloads}) roots) {
    final appSupport = roots.appSupport;
    final documents = roots.documents;
    final userDownloads = roots.userDownloads;
    // Separator-agnostic (Windows): compare through package:path so
    // `C:\...\app_support\file_recv\x` tokenizes like `/.../file_recv/x`.
    String? tailWithin(String root) {
      if (!p.isWithin(root, absolutePath)) return null;
      return p.relative(absolutePath, from: root).replaceAll('\\', '/');
    }
    if (appSupport != null) {
      final tail = tailWithin(p.join(appSupport, 'file_recv'));
      if (tail != null) return '{{fileRecv}}/$tail';
    }
    if (appSupport != null) {
      final tail = tailWithin(p.join(appSupport, 'avatars'));
      if (tail != null) return '{{avatars}}/$tail';
    }
    // R-5: keep the precise `documents/Downloads/` match BEFORE the
    // broader userDownloads check. On platforms where the user-level
    // Downloads dir happens to coincide with documents/Downloads/, we'd
    // otherwise emit the same path under two different placeholders.
    if (documents != null && absolutePath.startsWith('$documents/Downloads/')) {
      final tail = absolutePath.substring('$documents/Downloads/'.length);
      return '{{downloads}}/$tail';
    }
    if (userDownloads != null && absolutePath.startsWith('$userDownloads/')) {
      final tail = absolutePath.substring('$userDownloads/'.length);
      return '{{userDownloads}}/$tail';
    }
    return absolutePath;
  }

  /// P1-15: inverse of [_relativizePath]. Placeholder tokens are
  /// substituted with the current device's storage roots; absolute paths
  /// (legacy v1 entries) are returned unchanged.
  String _resolvePath(String storedPath,
      ({String? appSupport, String? documents, String? userDownloads}) roots) {
    final appSupport = roots.appSupport;
    final documents = roots.documents;
    final userDownloads = roots.userDownloads;
    // Inverse of the package:path tokenization above: rebuild with the
    // platform separator so the round-trip is string-stable on Windows too.
    if (storedPath.startsWith('{{fileRecv}}/') && appSupport != null) {
      final tail = storedPath.substring('{{fileRecv}}/'.length).split('/');
      return p.joinAll([appSupport, 'file_recv', ...tail]);
    }
    if (storedPath.startsWith('{{avatars}}/') && appSupport != null) {
      final tail = storedPath.substring('{{avatars}}/'.length).split('/');
      return p.joinAll([appSupport, 'avatars', ...tail]);
    }
    if (storedPath.startsWith('{{downloads}}/') && documents != null) {
      return '$documents/Downloads/${storedPath.substring('{{downloads}}/'.length)}';
    }
    // R-5: rehydrate the new userDownloads placeholder. Schema version
    // stays at 2 — older v2 files simply don't contain the token, and
    // unknown placeholders fall through to the unchanged-string return.
    if (storedPath.startsWith('{{userDownloads}}/') && userDownloads != null) {
      return '$userDownloads/${storedPath.substring('{{userDownloads}}/'.length)}';
    }
    return storedPath;
  }

  /// Get temporary file path for atomic writes
  Future<File> _getTempFile(String id) async {
    final file = await _getHistoryFile(id);
    return File('${file.path}.tmp');
  }

  /// Save message history for a conversation
  ///
  /// Thread-safe implementation with:
  /// - Write locks to prevent race conditions
  /// - Temporary file + atomic rename for data integrity
  /// - Backup mechanism for crash recovery
  ///
  /// [conversationId] - Normalized conversation ID
  /// [messages] - List of messages to save
  ///
  /// An EMPTY list is written only when it is the result of a delete: the
  /// conversation is loaded, its cached list is empty and a removal is still
  /// pending on disk (pre #2 / #4: deleting the sole row used to return here
  /// without touching the file, and the stale JSON brought the row back on
  /// the next launch). Any other empty list means "not loaded yet" and must
  /// never overwrite a file this process has not read.
  Future<void> saveHistory(String conversationId, List<ChatMessage> messages) {
    // Normalize conversation ID for consistent storage
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    if (messages.isEmpty && !_emptyIsADelete(normalizedId)) {
      return Future<void>.value();
    }
    if (_disposed) {
      // Closed store (see [dispose]); [openSession] reopens it.
      _logger?.logWarning(
          '[MessageHistoryPersistence] save after dispose ignored for '
          '$normalizedId');
      return Future<void>.value();
    }
    // Which deletes this save covers is fixed NOW, before any await: a
    // snapshot taken by an earlier caller must not be credited with a delete
    // that happened while it waited for the previous write.
    final deleteSeqAtStart = _deleteSeq;
    final token = _token(normalizedId);
    // C1: the lock slot is claimed synchronously inside [_serialized], so
    // concurrent callers serialize deterministically.
    return _serialized(normalizedId,
        () => _writeMainFile(normalizedId, messages, token, deleteSeqAtStart));
  }

  bool _emptyIsADelete(String normalizedId) =>
      (_historyById[normalizedId]?.isEmpty ?? false) &&
      (_recentlyDeleted[normalizedId]?.isNotEmpty ?? false);

  Future<void> _writeMainFile(String normalizedId, List<ChatMessage> messages,
      _OpToken token, int deleteSeqAtStart) async {
    // Cleared (or the whole store reset) while this save waited: the rows it
    // carries were discarded on purpose; writing them would resurrect them.
    if (_isStale(normalizedId, token)) return;
    try {
      final file = await _getHistoryFile(normalizedId);
      final backupFile = await _getBackupFile(normalizedId);
      final tempFile = await _getTempFile(normalizedId);

      // Create backup of existing file if it exists
      if (await file.exists()) {
        try {
          await file.copy(backupFile.path);
        } catch (e) {
          // Backup failed, but continue with save
        }
      }

      // Prepare data.
      //
      // P1-15: rewrite absolute filePaths under the well-known media-storage
      // roots into placeholders so a profile that moves between devices (or
      // re-installs that change the AppSupport path) doesn't end up with
      // dangling paths in its history. Unknown / outside-root paths are
      // left as-is to keep the change strictly additive.
      final storageRoots = await _resolveStorageRoots();
      // Overflow rows first: if this throws, the main file below is NOT
      // rewritten, so the rows it still holds are not lost.
      await _drainPendingArchive(normalizedId, storageRoots);
      final jsonList = messages.map((msg) {
        final m = msg.toJson();
        final fp = m['filePath'];
        if (fp is String && fp.isNotEmpty) {
          m['filePath'] = _relativizePath(fp, storageRoots);
        }
        return m;
      }).toList();
      final data = {
        'conversationId': normalizedId,
        // P1-15: bump format to 2 to signal that filePath may contain
        // placeholder tokens. v1 readers will treat them as opaque strings;
        // v2 readers rehydrate via [_resolvePath].
        'version': _historyFormatVersion,
        'lastViewTimestamp': _lastViewTimestampById[normalizedId] ?? 0,
        'messages': jsonList,
      };
      final jsonString = jsonEncode(data);

      // C2: write→fsync→close→rename for crash durability. Tox is P2P, no
      // server can backfill, so a half-flushed page-cache buffer at the
      // moment of a kernel/process crash means permanent data loss.
      final raf = await tempFile.open(mode: FileMode.write);
      try {
        await raf.writeString(jsonString);
        await raf.flush();
      } finally {
        await raf.close();
      }
      await _renameWithRetry(tempFile, file.path);
      // Deletes that happened before this save was called are on disk now.
      _clearTombstonesUpTo(normalizedId, deleteSeqAtStart);

      // X10: delete the backup we just used as a safety net.
      try {
        if (await backupFile.exists()) {
          await backupFile.delete();
        }
      } catch (_) {
        // Best-effort cleanup; leave the stale .bak for the 7-day sweep.
      }
      _saveRetryAttempts.remove(normalizedId);
      _saveRetryTimers.remove(normalizedId)?.cancel();
    } catch (e, st) {
      // GH-7: this used to settle only the fence completer and return
      // normally, so every caller's failure handling (updateFilePathSafely's
      // rollback, the hook's disk-quota catch) was dead and a failed write was
      // silent. Propagate it, and keep the in-memory state marked dirty so a
      // bounded retry re-attempts the write without waiting for the next
      // message.
      _armSaveRetry(normalizedId, e, st);
      rethrow;
    }
  }

  /// Re-save [normalizedId]'s cached list (debounce timer, retry timer,
  /// flush). Null when there is nothing this store may write: not cached, or
  /// an empty list that is not the result of a delete.
  Future<void>? _resaveCached(String normalizedId) {
    final list = _historyById[normalizedId];
    if (list == null) return null;
    if (list.isEmpty && !_emptyIsADelete(normalizedId)) return null;
    return saveHistory(normalizedId, List<ChatMessage>.from(list));
  }

  /// Write [normalizedId]'s queued overflow rows to its archive file, for a
  /// conversation that has nothing cached left to save — the shape
  /// `clearHistory(keepArchive: true)` leaves behind when the drain it does
  /// itself fails. Null when nothing is queued.
  Future<void>? _drainArchiveOnly(String normalizedId) {
    if (!(_pendingArchive[normalizedId]?.isNotEmpty ?? false)) return null;
    final token = _token(normalizedId);
    return _serialized(normalizedId, () async {
      if (_isStale(normalizedId, token)) return;
      await _drainPendingArchive(normalizedId, await _resolveStorageRoots());
    });
  }

  /// Atomic replace with a short bounded retry. On Windows an antivirus or
  /// search-indexer handle on the destination makes `MoveFileEx` fail with a
  /// sharing violation for a few milliseconds; one failed rename used to lose
  /// the whole write.
  Future<void> _renameWithRetry(File source, String targetPath) async {
    const maxAttempts = 4;
    for (var attempt = 1;; attempt++) {
      try {
        await source.rename(targetPath);
        return;
      } on FileSystemException {
        if (attempt >= maxAttempts) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 25 * attempt));
      }
    }
  }

  /// Schedules a re-save of [normalizedId]'s cached list after a failed write,
  /// with exponential backoff, at most [_maxSaveRetries] times in a row (a
  /// successful write resets the count; a later append always tries again).
  void _armSaveRetry(String normalizedId, Object error, StackTrace stack) {
    final attempt = (_saveRetryAttempts[normalizedId] ?? 0) + 1;
    _saveRetryAttempts[normalizedId] = attempt;
    _logger?.logError(
      '[MessageHistoryPersistence] history write failed for $normalizedId '
      '(consecutive failure $attempt)',
      error,
      stack,
    );
    if (_disposed || attempt > _maxSaveRetries) return;
    if (_saveRetryTimers.containsKey(normalizedId)) return;
    _saveRetryTimers[normalizedId] =
        Timer(_saveRetryBaseDelay * (1 << (attempt - 1)), () {
      _saveRetryTimers.remove(normalizedId);
      // Errors here re-arm through saveHistory's own catch.
      _resaveCached(normalizedId)?.ignore();
    });
  }

  /// Load message history for a conversation
  ///
  /// Returns the loaded messages and updates the in-memory cache.
  /// Marks all pending messages as not pending (failed) to prevent resending on startup.
  ///
  /// Includes file integrity checks and backup recovery.
  ///
  /// [id] - Conversation ID (will be normalized)
  /// [quitGroups] - Set of quit group IDs to filter out
  Future<List<ChatMessage>> loadHistory(String id,
      {Set<String>? quitGroups}) {
    final normalizedId = ConversationIdUtils.normalize(id);
    // #10 / pre #3: the token is taken at CALL time and the read + install
    // run under the conversation lock. A save queued before this load lands
    // first (the load reads its result); one queued after waits until the
    // load has installed; a clear bumps the generation and the load then
    // installs nothing. The old code snapshotted the in-flight write before
    // an await, so a writer registering after the snapshot but before the
    // read let the load reinstall pre-save (pre-delete) rows.
    final token = _token(normalizedId);
    return _serialized(normalizedId,
        () => _loadHistoryLocked(id, normalizedId, token, quitGroups));
  }

  Future<List<ChatMessage>> _loadHistoryLocked(String id, String normalizedId,
      _OpToken token, Set<String>? quitGroups) async {
    if (_isStale(normalizedId, token)) return [];
    try {
      final file = await _getHistoryFile(normalizedId);
      if (!await file.exists()) {
        // Try to load from backup
        return await _loadFromBackup(normalizedId, token,
            quitGroups: quitGroups);
      }

      // Check file size (empty or corrupted file)
      final fileSize = await file.length();
      if (fileSize == 0) {
        return await _loadFromBackup(normalizedId, token,
            quitGroups: quitGroups);
      }

      String jsonString;
      try {
        jsonString = await file.readAsString();
      } catch (e) {
        // File read failed, try backup
        return await _loadFromBackup(normalizedId, token,
            quitGroups: quitGroups);
      }

      dynamic decoded;
      try {
        decoded = jsonDecode(jsonString);
      } catch (e) {
        // JSON parse failed, try to recover from backup
        return await _recoverCorruptedFile(file, normalizedId, token,
            quitGroups: quitGroups);
      }

      List<ChatMessage> messages;
      String? actualId;

      // P1-15: resolve storage roots once per load so we can rehydrate
      // placeholder filePaths into absolute device paths.
      final storageRoots = await _resolveStorageRoots();

      // One undecodable row (a null `text`, a bad timestamp, a field from a
      // newer build) used to throw out of the whole map() and the conversation
      // loaded as EMPTY; the next append then rewrote the file with one row.
      var skippedRows = 0;
      List<ChatMessage> decodeRows(List<dynamic> jsonList) {
        final rows = <ChatMessage>[];
        for (final json in jsonList) {
          try {
            final m = json as Map<String, dynamic>;
            final fp = m['filePath'];
            if (fp is String && fp.isNotEmpty) {
              m['filePath'] = _resolvePath(fp, storageRoots);
            }
            rows.add(ChatMessage.fromJson(m));
          } catch (_) {
            skippedRows++;
          }
        }
        return rows;
      }

      if (decoded is Map<String, dynamic>) {
        // A file written by a NEWER schema: loading it with this build's
        // model and saving it back would silently strip what we don't know.
        final fileVersion = (decoded['version'] as int?) ?? 1;
        if (fileVersion > _historyFormatVersion) {
          await _quarantine(file, 'newer-v$fileVersion');
          return [];
        }
        // New format with metadata
        actualId = decoded['conversationId'] as String?;
        // Load lastViewTimestamp if available (default to 0 if not present)
        final lastViewTimestamp = decoded['lastViewTimestamp'] as int? ?? 0;
        final rawMessages = decoded['messages'];
        if (rawMessages is! List<dynamic>) {
          // Valid JSON, wrong shape: same handling as unparseable JSON.
          return await _recoverCorruptedFile(file, normalizedId, token,
              quitGroups: quitGroups);
        }
        messages = decodeRows(rawMessages);
        // Store lastViewTimestamp in memory cache
        final targetIdForTimestamp = actualId ?? id;
        if (!_isStale(normalizedId, token)) {
          _lastViewTimestampById[targetIdForTimestamp] = lastViewTimestamp;
        }
      } else if (decoded is List<dynamic>) {
        // Old format (backward compatibility)
        messages = decodeRows(decoded);
        // Try to infer ID from messages
        if (messages.isNotEmpty) {
          final firstMsg = messages.first;
          actualId = firstMsg.groupId ??
              id; // Use groupId if available, otherwise use provided id
        } else {
          actualId = id;
        }
      } else {
        return [];
      }

      if (skippedRows > 0) {
        _logger?.logWarning(
          '[MessageHistoryPersistence] $normalizedId: skipped $skippedRows '
          'undecodable row(s); original file preserved',
        );
        // The post-load save below drops those rows from the main file, so
        // keep the original bytes around for recovery.
        await _quarantine(file, 'partial', copy: true);
      }

      // Normalize the actual ID from file
      final targetId = actualId != null
          ? ConversationIdUtils.normalize(actualId)
          : normalizedId;

      // Check if this is a quit group (if quitGroups is provided)
      if (quitGroups != null && messages.isNotEmpty) {
        final firstMsg = messages.first;
        final isGroupConversation =
            firstMsg.groupId != null && firstMsg.groupId!.isNotEmpty;
        if (isGroupConversation) {
          final groupId = firstMsg.groupId!;
          if (quitGroups.contains(groupId)) {
            // This group was quit, don't load its history
            // Also clean up the history file
            try {
              await file.delete();
            } catch (e) {
              // Ignore deletion errors
            }
            await _deleteArchive(normalizedId);
            return [];
          }
        }
      }

      // Legacy layouts (bare list, or a v1 map with absolute filePaths) are
      // upgraded to the current format by the post-load save.
      return _installLoadedHistory(
        targetId,
        messages,
        lockId: normalizedId,
        token: token,
        legacyLayout: decoded is List<dynamic> ||
            (decoded is Map<String, dynamic> &&
                ((decoded['version'] as int?) ?? 1) < 2),
        skippedRows: skippedRows,
      );
    } catch (e) {
      // Try to load from backup on any error
      return await _loadFromBackup(normalizedId, token,
          quitGroups: quitGroups);
    }
  }

  /// Post-decode half of [loadHistory], shared with backup recovery so rows
  /// restored from `.bak` land in the cache exactly like a normal load (GH-10:
  /// they used to be returned without ever being cached, so the next append
  /// started a fresh one-row list and saved it over the recovered history).
  ///
  /// Returns a COPY of the installed list: callers sort what they get back
  /// (newest-first for previews), and sorting the live cache list in place
  /// reversed its arrival order for every later append and memory trim.
  List<ChatMessage> _installLoadedHistory(
    String targetId,
    List<ChatMessage> messages, {
    required String lockId,
    required _OpToken token,
    required bool legacyLayout,
    int skippedRows = 0,
  }) {
    // Cleared / reset while the file was being read: install nothing.
    if (_isStale(lockId, token)) return [];
    // Legacy layouts (bare list, v1 map with absolute filePaths) and backup
    // recoveries are rewritten in the current format by the post-load save.
    var normalizedOnLoad = legacyLayout;
    // Mark all historical messages as not pending (they're from previous sessions)
    // This prevents old pending messages from being resent on startup
    final updatedMessages = messages.map((msg) {
      if (msg.isPending) {
        normalizedOnLoad = true;
        // Mark as not pending (failed to send in a previous session) while
        // preserving EVERY other field. copyWith (not a hand-listed
        // ChatMessage(...)) keeps cloudCustomData (S17/S18 reply/forward
        // quote) and altMsgIds (cross-path aliases) — a manual reconstruction
        // silently dropped both, so a quoted reply lost its messageReply
        // metadata across an app restart.
        return msg.copyWith(isPending: false);
      }
      return msg;
    }).toList();

    // CRITICAL: collapse rows that are the same logical message — same
    // primary msgID, or (#5) a shared cross-path alias (`altMsgIds`, e.g. the
    // NGC `gmid:` identity or a hybrid-path id absorbed by content dedup).
    // Matching on the primary id alone left the poll-path and binary-path
    // copies of one message as two rows after a restart. The winner keeps
    // every id either copy carried, so receipts / deletes by the dropped id
    // still resolve. Rows DELETED in memory but not yet on disk are dropped
    // here whatever the live cache holds (#4: the filter used to run only
    // when the live list was non-empty, so a deleted SOLE row came back).
    var tombstoned = 0;
    final deleted = _recentlyDeleted[targetId] ?? const <String, int>{};
    final deduplicatedList = _dedupeByIdentity(updatedMessages).where((m) {
      final gone = identitiesOf(m).any(deleted.containsKey);
      if (gone) tombstoned++;
      return !gone;
    }).toList();
    // Stable (GH-6): rows with equal timestamps keep their on-disk (= arrival)
    // order.
    sortChatMessagesChronologically(deduplicatedList);

    // If lastViewTimestamp was not loaded from file, initialize it to 0
    if (!_lastViewTimestampById.containsKey(targetId)) {
      _lastViewTimestampById[targetId] = 0;
    }

    // Reconcile the persisted read state with the view barrier: a non-self
    // message at or before the last-viewed timestamp was seen, so mark it
    // read even if its stored isRead flag predates read-state tracking. This
    // makes isRead the authoritative unread signal in [getUnreadCount], so a
    // later message that arrives with a timestamp <= the barrier (clock skew
    // or same-millisecond) is still counted instead of being silently
    // suppressed by a strict `ts > lastView` comparison. In-memory only —
    // not persisted here, so it re-applies cheaply on each load.
    final barrierForReconcile = _lastViewTimestampById[targetId] ?? 0;
    if (barrierForReconcile > 0) {
      for (int i = 0; i < deduplicatedList.length; i++) {
        final m = deduplicatedList[i];
        if (!m.isSelf &&
            !m.isRead &&
            m.timestamp.millisecondsSinceEpoch <= barrierForReconcile) {
          deduplicatedList[i] = m.copyWith(isRead: true);
        }
      }
    }

    // Save the updated history (with isPending=false and deduplicated) to disk if any changes were made.
    // The save is fire-and-forget so a slow disk write doesn't block load,
    // but we wrap with catchError so a serialization or I/O failure surfaces
    // through the injected logger instead of bubbling out as an uncaught
    // async error on cold start. The cold-start parallel batch can launch
    // many of these concurrently — without this, any one disk-write failure
    // would crash the zone.
    // M1: instead of fire-and-forget `unawaited(saveHistory(...))` on every
    // load-time normalization, mark this conversation dirty and let
    // `loadAllHistories` flush them serially after the batch completes.
    // The old behaviour spawned 16+ concurrent saveHistory futures from
    // each cold-start batch, all racing on the per-conversation fence.
    //
    // Only when the load actually changed something. This used to compare
    // `updatedMessages != messages` — two distinct List objects, so always
    // true — and every cold start rewrote EVERY history file (backup copy +
    // full JSON encode + fsync + rename per conversation, serialized, before
    // login could proceed).
    if (deduplicatedList.length != messages.length ||
        normalizedOnLoad ||
        skippedRows > 0) {
      _dirtyAfterLoad.add(targetId);
    }

    // GH-10: the file was read across awaits, and an append (or an alias /
    // read-state update) may have landed in the live cache meanwhile.
    // Replacing the list dropped it; worse, that append's debounced save may
    // already have written its one-row list over the file. The live rows are
    // the newer state and win; the file contributes only rows the cache lacks.
    // The list object is updated IN PLACE so references handed out by
    // [getCachedList] stay the conversation's list.
    final live = _historyById[targetId];
    if (live == null || live.isEmpty) {
      if (deduplicatedList.isEmpty) {
        // Nothing to show (an emptied-by-delete file, or everything in it was
        // tombstoned). Do not create an empty cache entry: an empty cached
        // list is "loaded and empty", which would let a later save of it
        // count as a delete.
        if (tombstoned > 0 && live != null) {
          // The file still holds rows deleted in memory: persist the delete.
          _scheduleDebouncedSave(targetId).ignore();
        }
        return [];
      }
      if (live == null) {
        _historyById[targetId] = deduplicatedList;
      } else {
        // Keep the list object handed out by [getCachedList].
        live.addAll(deduplicatedList);
      }
      if (tombstoned > 0) _scheduleDebouncedSave(targetId).ignore();
      return List<ChatMessage>.from(deduplicatedList);
    }
    final liveIds = <String>{for (final m in live) ...identitiesOf(m)};
    final fileIds = <String>{
      for (final m in deduplicatedList) ...identitiesOf(m),
    };
    // Tombstoned rows were already filtered out above.
    final fromFileOnly = deduplicatedList
        .where((m) => !identitiesOf(m).any(liveIds.contains))
        .toList();
    final liveOnly =
        live.any((m) => !identitiesOf(m).any(fileIds.contains));
    if (fromFileOnly.isNotEmpty) {
      final merged = <ChatMessage>[...fromFileOnly, ...live];
      sortChatMessagesChronologically(merged);
      live
        ..clear()
        ..addAll(merged);
    }
    if (fromFileOnly.isNotEmpty || liveOnly) {
      // The file no longer matches memory: write the union.
      _scheduleDebouncedSave(targetId).ignore();
    }
    return List<ChatMessage>.from(live);
  }

  /// Load history from backup file
  Future<List<ChatMessage>> _loadFromBackup(
      String normalizedId, _OpToken token,
      {Set<String>? quitGroups}) async {
    try {
      final backupFile = await _getBackupFile(normalizedId);
      if (!await backupFile.exists()) {
        return [];
      }

      final jsonString = await backupFile.readAsString();
      final decoded = jsonDecode(jsonString);

      // Use the same loading logic as loadHistory
      // This is a simplified version - in production, consider refactoring
      if (decoded is Map<String, dynamic>) {
        final jsonList = decoded['messages'] as List<dynamic>?;
        if (jsonList == null) return [];

        // P1-15: rehydrate placeholder filePaths in the backup too. Row-
        // tolerant like the main load: one bad row costs that row only.
        final storageRoots = await _resolveStorageRoots();
        final messages = <ChatMessage>[];
        for (final json in jsonList) {
          try {
            final m = json as Map<String, dynamic>;
            final fp = m['filePath'];
            if (fp is String && fp.isNotEmpty) {
              m['filePath'] = _resolvePath(fp, storageRoots);
            }
            messages.add(ChatMessage.fromJson(m));
          } catch (_) {
            // Skip the undecodable row.
          }
        }

        // Check quit groups
        if (quitGroups != null && messages.isNotEmpty) {
          final firstMsg = messages.first;
          if (firstMsg.groupId != null &&
              quitGroups.contains(firstMsg.groupId)) {
            return [];
          }
        }
        if (messages.isEmpty) return [];

        final actualId = decoded['conversationId'] as String?;
        final targetId = actualId != null
            ? ConversationIdUtils.normalize(actualId)
            : normalizedId;
        if (_isStale(normalizedId, token)) return [];
        final lastView = decoded['lastViewTimestamp'];
        if (lastView is int && !_lastViewTimestampById.containsKey(targetId)) {
          _lastViewTimestampById[targetId] = lastView;
        }
        // GH-10: cache it like a normal load (and mark it for rewrite into
        // the main file) instead of handing back rows nothing else knows of.
        return _installLoadedHistory(
          targetId,
          messages,
          lockId: normalizedId,
          token: token,
          legacyLayout: true,
        );
      }

      return [];
    } catch (e) {
      return [];
    }
  }

  /// Recover from corrupted file
  Future<List<ChatMessage>> _recoverCorruptedFile(
      File corruptedFile, String normalizedId, _OpToken token,
      {Set<String>? quitGroups}) async {
    // Try backup first
    final backupMessages =
        await _loadFromBackup(normalizedId, token, quitGroups: quitGroups);
    if (backupMessages.isNotEmpty) {
      // M2: restore via read→tmp+fsync→rename, not `backup.copy(primary)`.
      // A direct copy is not crash-safe — if killed mid-copy the primary is
      // now partially written *and* the backup is untouched (but soon
      // overwritten by the next save), leaving both files unusable.
      try {
        final backupFile = await _getBackupFile(normalizedId);
        if (await backupFile.exists()) {
          final backupContent = await backupFile.readAsString();
          final tempFile = await _getTempFile(normalizedId);
          final raf = await tempFile.open(mode: FileMode.write);
          try {
            await raf.writeString(backupContent);
            await raf.flush();
          } finally {
            await raf.close();
          }
          await tempFile.rename(corruptedFile.path);
        }
      } catch (e) {
        // Restore failed, but we have messages in memory
      }
      return backupMessages;
    }

    // Unreadable and no backup. Returning [] alone was destructive: the next
    // append created a one-row list, and saveHistory copied THIS corrupt file
    // over the backup slot, renamed the new file on top of it and deleted the
    // backup — the evidence was gone for good. Move it aside instead.
    await _quarantine(corruptedFile, 'corrupt');
    return [];
  }

  /// Preserve a history file this build cannot (fully) read, out of the way of
  /// every later save. The name does NOT end in `.json`, so
  /// [loadAllHistories] never picks it up, and [cleanupTempFiles] leaves it.
  Future<void> _quarantine(File file, String reason, {bool copy = false}) async {
    try {
      final target =
          '${file.path}.$reason-${DateTime.now().millisecondsSinceEpoch}';
      if (copy) {
        await file.copy(target);
      } else {
        await file.rename(target);
      }
      _logger?.logWarning(
          '[MessageHistoryPersistence] preserved unreadable history as $target');
    } catch (e, st) {
      _logger?.logError(
          '[MessageHistoryPersistence] could not preserve ${file.path}', e, st);
    }
  }

  /// Load all message histories from disk.
  ///
  /// Scans the chat_history directory and loads all conversation histories.
  /// Returns a map of conversationId -> messages.
  ///
  /// Performance (P4 in `local-storage-review-2026-05-18.md`): files are loaded
  /// in parallel batches via `Future.wait` to overlap disk I/O. The batch size
  /// is bounded so we don't open hundreds of file handles on cold start (e.g.
  /// 500-conversation install). Per-file errors are swallowed so a single bad
  /// file can't block the rest of the boot — same semantics as the previous
  /// sequential loop, just concurrent within each batch.
  Future<Map<String, List<ChatMessage>>> loadAllHistories(
      {Set<String>? quitGroups}) async {
    final result = <String, List<ChatMessage>>{};

    try {
      final dir = await _getHistoryDirectory();
      if (!await dir.exists()) {
        return result;
      }

      final entries = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList(growable: false);

      // Bounded parallelism: open at most `batchSize` files concurrently to
      // avoid file-descriptor exhaustion on installs with many conversations.
      const int batchSize = 16;
      for (var start = 0; start < entries.length; start += batchSize) {
        final end = (start + batchSize) > entries.length
            ? entries.length
            : (start + batchSize);
        final batch = entries.sublist(start, end);

        final loaded = await Future.wait(
          batch.map((file) => _loadOneForLoadAll(file, quitGroups: quitGroups)),
        );

        for (final entry in loaded) {
          if (entry == null) continue;
          result[entry.key] = entry.value;
        }
      }
    } catch (e) {
      // Return whatever we've loaded so far
    }

    // M1: drain post-load normalization writes serially so we don't fan out
    // hundreds of concurrent fence-contending saves on cold start.
    await flushDirtyAfterLoad();

    return result;
  }

  /// Flush the post-load dirty set (see [_dirtyAfterLoad]) — serial writes so
  /// the per-conversation write fence doesn't end up with a tall waiter chain
  /// on first boot. Errors are routed through the injected logger and do not
  /// abort the remaining flushes.
  Future<void> flushDirtyAfterLoad() async {
    if (_dirtyAfterLoad.isEmpty) return;
    final ids = List<String>.from(_dirtyAfterLoad);
    _dirtyAfterLoad.clear();
    for (final id in ids) {
      final list = _historyById[id];
      if (list == null) continue;
      try {
        await saveHistory(id, List<ChatMessage>.from(list));
      } catch (e, st) {
        _logger?.logError(
          '[MessageHistoryPersistence] post-load save failed for $id',
          e,
          st,
        );
      }
    }
  }

  /// Helper for [loadAllHistories]: load a single conversation file and return
  /// its (conversationKey, messages) entry, or null if it produced no messages
  /// or failed. Errors are swallowed to preserve the previous "skip bad files"
  /// behaviour of the sequential implementation.
  Future<MapEntry<String, List<ChatMessage>>?> _loadOneForLoadAll(
    File file, {
    Set<String>? quitGroups,
  }) async {
    try {
      final filename = file.path.split(Platform.pathSeparator).last;
      // On POSIX the previous code split on '/'; preserve that fallback for
      // paths that may use forward slashes regardless of platform separator.
      final canonicalFilename =
          filename.contains('/') ? filename.split('/').last : filename;
      final sanitizedId = canonicalFilename.replaceAll('.json', '');

      final messages = await loadHistory(sanitizedId, quitGroups: quitGroups);
      if (messages.isEmpty) return null;

      // Key on the (normalized) filename: see the long-form comment in the
      // previous implementation about why firstMsg.fromUserId is the wrong
      // key for C2C conversations the user has sent into.
      final conversationKey = ConversationIdUtils.normalize(sanitizedId);
      return MapEntry(conversationKey, messages);
    } catch (_) {
      return null;
    }
  }

  /// Append [_pendingArchive] rows for [normalizedId] to its archive file
  /// (write + fsync). Must run inside the conversation's write fence. Throws
  /// on I/O failure, leaving the rows queued.
  Future<void> _drainPendingArchive(
    String normalizedId,
    ({String? appSupport, String? documents, String? userDownloads})
        storageRoots,
  ) async {
    final pending = _pendingArchive[normalizedId];
    if (pending == null || pending.isEmpty) return;
    final batch = List<ChatMessage>.from(pending);
    final buffer = StringBuffer();
    for (final msg in batch) {
      final m = msg.toJson();
      final fp = m['filePath'];
      if (fp is String && fp.isNotEmpty) {
        m['filePath'] = _relativizePath(fp, storageRoots);
      }
      buffer.writeln(jsonEncode(m));
    }
    final archiveFile = await _getArchiveFile(normalizedId);
    final raf = await archiveFile.open(mode: FileMode.append);
    try {
      await raf.writeString(buffer.toString());
      await raf.flush();
    } finally {
      await raf.close();
    }
    // Only now are the rows durable. Rows queued while we were writing stay.
    final current = _pendingArchive[normalizedId];
    if (current != null) {
      // By identity, not position: removeArchivedMessages may have dropped
      // rows from this list (and new overflow rows been appended) while the
      // write was in flight; a positional removeRange then discarded a row
      // that was never written.
      final written = Set<ChatMessage>.identity()..addAll(batch);
      current.removeWhere(written.contains);
      if (current.isEmpty) _pendingArchive.remove(normalizedId);
    }
    if (_archiveCacheId == normalizedId) {
      _archiveCacheId = null;
      _archiveCacheRows = null;
    }
  }

  /// Whether rows older than the in-memory window exist for this conversation.
  Future<bool> hasArchivedHistory(String conversationId) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    if (_pendingArchive[normalizedId]?.isNotEmpty ?? false) return true;
    try {
      final archiveFile = await _getArchiveFile(normalizedId);
      return await archiveFile.exists() && await archiveFile.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// Rows older than the in-memory window, oldest first. Excludes anything
  /// still present in memory (a crash between the archive append and the
  /// main-file rewrite leaves a row in both), and tolerates damaged lines:
  /// one bad line costs that line, not the archive.
  Future<List<ChatMessage>> loadArchivedHistory(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final cached = _archiveCacheId == normalizedId ? _archiveCacheRows : null;
    // Cache hit: the cache is invalidated (under the lock) by every drain,
    // rewrite and clear, so cached disk rows + CURRENT pending rows are a
    // consistent view.
    if (cached != null) {
      return Future.value(_archivedView(normalizedId, cached));
    }
    // #6: the read runs under the conversation lock, so it can neither
    // straddle a drain (seeing a row both on disk and still pending) nor
    // repopulate the cache with rows a delete / clear just removed.
    final token = _token(normalizedId);
    return _serialized(normalizedId, () async {
      if (_isStale(normalizedId, token)) return <ChatMessage>[];
      final rows = <ChatMessage>[];
      try {
        final archiveFile = await _getArchiveFile(normalizedId);
        if (await archiveFile.exists()) {
          final storageRoots = await _resolveStorageRoots();
          for (final line in await archiveFile.readAsLines()) {
            if (line.trim().isEmpty) continue;
            try {
              final m = jsonDecode(line) as Map<String, dynamic>;
              final fp = m['filePath'];
              if (fp is String && fp.isNotEmpty) {
                m['filePath'] = _resolvePath(fp, storageRoots);
              }
              final msg = ChatMessage.fromJson(m);
              rows.add(msg.isPending ? msg.copyWith(isPending: false) : msg);
            } catch (_) {
              // Torn final line after a crash, or a damaged row: skip it.
            }
          }
        }
      } catch (e, st) {
        _logger?.logError(
          '[MessageHistoryPersistence] archive read failed for $normalizedId',
          e,
          st,
        );
        // Not cached: a transient failure must not pin an empty archive.
        return _archivedView(normalizedId, const <ChatMessage>[]);
      }
      if (_isStale(normalizedId, token)) return <ChatMessage>[];
      // #5: one logical message appended twice (a re-archived row, a
      // cross-path duplicate) collapses on ANY shared identity.
      final sortedRows = _dedupeByIdentity(rows);
      // Stable (GH-6): equal timestamps keep archive-line (= arrival) order.
      sortChatMessagesChronologically(sortedRows);
      _archiveCacheId = normalizedId;
      _archiveCacheRows = sortedRows;
      return _archivedView(normalizedId, sortedRows);
    });
  }

  /// Disk archive rows + rows still queued for the archive, deduplicated by
  /// identity, minus anything still in the in-memory window (a crash between
  /// the archive append and the main-file rewrite leaves a row in both) and
  /// minus rows deleted in memory whose removal is not on disk yet.
  List<ChatMessage> _archivedView(
      String normalizedId, List<ChatMessage> diskRows) {
    final pending = _pendingArchive[normalizedId];
    final combined = pending == null || pending.isEmpty
        ? List<ChatMessage>.from(diskRows)
        : _dedupeByIdentity(<ChatMessage>[...diskRows, ...pending]);
    if (pending != null && pending.isNotEmpty) {
      sortChatMessagesChronologically(combined);
    }
    final excluded = <String>{
      for (final m in _historyById[normalizedId] ?? const <ChatMessage>[])
        ...identitiesOf(m),
      ...?_recentlyDeleted[normalizedId]?.keys,
    };
    if (excluded.isEmpty) return combined;
    return combined
        .where((m) => !identitiesOf(m).any(excluded.contains))
        .toList();
  }

  /// Delete archived rows by id (primary or alias). Returns how many went.
  /// Rewrites the archive atomically; rare (a user deleting very old rows).
  ///
  /// #9: the delete is only reported once it is durable. Queued (not yet
  /// archived) rows are dropped only after the disk rewrite succeeded, and a
  /// failed rewrite PROPAGATES — it used to be logged and swallowed after the
  /// queued rows were already gone, so the caller reported success while the
  /// archive kept the row for the next launch.
  Future<int> removeArchivedMessages(
      String conversationId, Set<String> msgIDs) async {
    final removed = await _removeArchivedRows(
        ConversationIdUtils.normalize(conversationId), msgIDs);
    return removed.length;
  }

  Future<List<ChatMessage>> _removeArchivedRows(
      String normalizedId, Set<String> msgIDs) {
    if (msgIDs.isEmpty) return Future.value(const <ChatMessage>[]);
    bool hit(ChatMessage m) =>
        (m.msgID != null && msgIDs.contains(m.msgID)) ||
        m.altMsgIds.any(msgIDs.contains);
    final token = _token(normalizedId);
    return _serialized(normalizedId, () async {
      if (_isStale(normalizedId, token)) return const <ChatMessage>[];
      final removed = <ChatMessage>[];
      try {
        final archiveFile = await _getArchiveFile(normalizedId);
        if (await archiveFile.exists()) {
          final kept = <String>[];
          for (final line in await archiveFile.readAsLines()) {
            if (line.trim().isEmpty) continue;
            try {
              final msg = ChatMessage.fromJson(
                  jsonDecode(line) as Map<String, dynamic>);
              if (hit(msg)) {
                removed.add(msg);
                continue;
              }
            } catch (_) {
              // Keep lines we cannot parse: deleting one row must not cost
              // others.
            }
            kept.add(line);
          }
          if (removed.isNotEmpty) {
            if (kept.isEmpty) {
              await archiveFile.delete();
            } else {
              final tempFile = File('${archiveFile.path}.tmp');
              final raf = await tempFile.open(mode: FileMode.write);
              try {
                await raf.writeString('${kept.join('\n')}\n');
                await raf.flush();
              } finally {
                await raf.close();
              }
              await _renameWithRetry(tempFile, archiveFile.path);
            }
          }
        }
      } catch (e, st) {
        _logger?.logError(
          '[MessageHistoryPersistence] archive delete failed for $normalizedId',
          e,
          st,
        );
        rethrow;
      } finally {
        // Whatever happened on disk, the parsed view may be stale now.
        if (_archiveCacheId == normalizedId) {
          _archiveCacheId = null;
          _archiveCacheRows = null;
        }
      }
      // Durable: now the queued copies (never written) may go too.
      final pending = _pendingArchive[normalizedId];
      if (pending != null) {
        pending.removeWhere((m) {
          if (!hit(m)) return false;
          removed.add(m);
          return true;
        });
        if (pending.isEmpty) _pendingArchive.remove(normalizedId);
      }
      return removed;
    });
  }

  /// Conversations that have an archive: queued overflow rows, or an
  /// `*.archive.jsonl` on disk. Includes conversations with NO in-memory rows
  /// (#22: after the last in-memory row of a conversation was deleted, its
  /// main file is gone and only the archive remains; [getConversationIds]
  /// does not list it, so a delete of an archived row there was skipped).
  Future<Set<String>> getArchivedConversationIds() async {
    final ids = <String>{
      for (final entry in _pendingArchive.entries)
        if (entry.value.isNotEmpty) entry.key,
    };
    try {
      final dir = await _getHistoryDirectory();
      const suffix = '.archive.jsonl';
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.endsWith(suffix)) continue;
        final id = name.substring(0, name.length - suffix.length);
        if (id.isNotEmpty) ids.add(ConversationIdUtils.normalize(id));
      }
    } catch (e, st) {
      _logger?.logError(
          '[MessageHistoryPersistence] archive listing failed', e, st);
    }
    return ids;
  }

  /// Delete archived rows matching [msgIDs] from EVERY conversation that has
  /// an archive (see [getArchivedConversationIds]). Returns how many went.
  /// Propagates a failed archive rewrite (see [removeArchivedMessages]).
  Future<int> removeArchivedMessagesEverywhere(Set<String> msgIDs) async =>
      (await removeArchivedRowsEverywhere(msgIDs)).length;

  /// [removeArchivedMessagesEverywhere], returning the rows that were removed
  /// so a caller can tell an archived DUPLICATE of a row it already deleted in
  /// memory from a row that only existed in the archive.
  Future<List<ChatMessage>> removeArchivedRowsEverywhere(
      Set<String> msgIDs) async {
    if (msgIDs.isEmpty) return const <ChatMessage>[];
    final removed = <ChatMessage>[];
    for (final id in await getArchivedConversationIds()) {
      removed.addAll(await _removeArchivedRows(id, msgIDs));
    }
    return removed;
  }

  /// Drop the archive (file, queued rows, cache) of a conversation.
  Future<void> _deleteArchive(String normalizedId) async {
    _pendingArchive.remove(normalizedId);
    if (_archiveCacheId == normalizedId) {
      _archiveCacheId = null;
      _archiveCacheRows = null;
    }
    try {
      final archiveFile = await _getArchiveFile(normalizedId);
      if (await archiveFile.exists()) {
        await archiveFile.delete();
      }
    } catch (_) {
      // Best-effort, same as the main file.
    }
  }

  /// Append a message to the history for a conversation.
  ///
  /// Updates the in-memory cache synchronously and returns a Future that
  /// completes when the on-disk save has finished (or errored). Callers that
  /// want to detect disk failures should `await` the result; callers that are
  /// happy with fire-and-forget should wrap with `unawaited(...)`.
  ///
  /// Limits memory usage by keeping only the most recent _maxMessagesInMemory
  /// messages in memory. Older rows move to the conversation's append-only
  /// archive file ([loadArchivedHistory]); nothing is dropped from disk.
  ///
  /// Deduplication, in priority order:
  ///   1. msgID match → merge via [_mergeMessages] (handles file_request /
  ///      file_done multi-event sequences for the same message).
  ///   2. Content fallback, INCOMING messages only (`!isSelf`), when the msgID
  ///      matched nothing → match on (fromUserId, text, timestamp within 2s).
  ///      This collapses the inbound hybrid double-delivery (same received
  ///      message via both paths with different ids). It is deliberately NOT
  ///      applied to self-sends: those never double-deliver, so collapsing
  ///      them would silently drop a legitimate repeated message ("Bug F").
  ///      See the inline comment at the fallback for the full rationale.
  ///
  /// [conversationId] - Will be normalized before use.
  Future<void> appendHistory(String conversationId, ChatMessage message) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    if (_disposed) {
      // A straggler from a closed session (late native callback). Its cache
      // is gone: caching and saving this row would write a one-row list over
      // the conversation's file.
      _logger?.logWarning(
          '[MessageHistoryPersistence] append after dispose ignored for '
          '$normalizedId');
      return Future.value();
    }
    final list = _historyById.putIfAbsent(normalizedId, () => <ChatMessage>[]);

    // Every identity the incoming row carries: its primary id plus any alias
    // (notably the NGC group alias `gmid:<gid>|<SENDER>|<id>` that both
    // inbound paths stamp, GH-4).
    final incomingIds = <String>[
      if (message.msgID != null) message.msgID!,
      ...message.altMsgIds,
    ];
    if (incomingIds.isNotEmpty) {
      // Match on the primary id OR an absorbed cross-path alias, so a
      // re-delivery carrying a previously-dropped id merges into the row that
      // absorbed it instead of appending a third copy.
      // Never across directions: an inbound row and one of our own rows can
      // share a group alias only when both are the SAME logical message seen
      // from both ends (a shared test harness), never as a re-delivery.
      final existingIndex = list.indexWhere((msg) =>
          msg.isSelf == message.isSelf &&
          incomingIds.any((id) => _idMatches(msg, id)));
      if (existingIndex >= 0) {
        final existing = list[existingIndex];
        list[existingIndex] = _mergeMessages(existing, message);
        // Merge of an existing message: in-memory state is already consistent.
        // Schedule a debounced save instead of writing immediately so a burst
        // of file_request / file_done updates for the same msgID coalesces.
        return _scheduleDebouncedSave(normalizedId);
      }
      // Fall through to the content-based dedup below — do NOT return here.
      // A non-null msgID that matched nothing is NOT proof the message is new:
      // toxee's hybrid runtime delivers the SAME inbound message through BOTH
      // paths with DIFFERENT ids (binary-replacement V2TimAdvancedMsgListener
      // `msg_<n>_<nanos>_<seq>` vs FfiChatService poll `<millis>_<n>_<toxId>`).
      // The two ids never match, so an early `list.add` here persists the echo
      // twice. _mergeMessages preserves the dropped id in altMsgIds so it stays
      // resolvable. Mirrors BinaryReplacementHistoryHook's "msgID OR content".
    }

    // Content-based dedup fallback. Runs when the message has no msgID OR has
    // an msgID that matched nothing above (the cross-path duplicate case).
    // Same heuristic as the binary-replacement hook: (text, fromUserId) within
    // a 2s window.
    //
    // INCOMING ONLY (`!message.isSelf`). The reason this fallback exists is the
    // INBOUND hybrid double-delivery: the same received message arrives via
    // both the binary-replacement path (`msg_<n>_<nanos>_<seq>`) and the poll
    // path (`<millis>_<n>_<toxId>`) with different ids ms apart, and only
    // content can collapse them. Outbound (self) messages do NOT double-deliver
    // — Tox does not loop a sender's own message back, so the hook never writes
    // self-sends; `FfiChatService.sendText` appends each self row exactly once
    // with a unique sequenced msgID, and the offline pending→delivered drain
    // reconciles in place by reusing the pending row's msgID (it does not
    // re-append). Running content-dedup on self-sends was therefore over-reach:
    // it silently DROPPED a legitimate second identical self message sent
    // inside 2s (e.g. double-tap send, or "ok" then "ok") — "Bug F". Gating on
    // `!message.isSelf` fixes that while leaving the inbound merge (the only
    // case that needs it) untouched. The drain crash-recovery fallback that
    // *does* re-append a self row does its own content existence check
    // (`_drainTextItem`), so it no longer relies on this branch.
    if (message.text.isNotEmpty && !message.isSelf) {
      const dedupWindow = Duration(seconds: 2);
      // GH-4: only when identity is UNKNOWN on one side (legacy /
      // conference / an older native library). Two rows that both carry a
      // group alias and did not match exactly above are two genuine
      // messages: a member sending "ok" twice within the window.
      final contentMatch = list.indexWhere((msg) =>
          chatMessagesShareGroupIdentity(msg, message) == null &&
          msg.text == message.text &&
          msg.fromUserId == message.fromUserId &&
          msg.contentKind == message.contentKind &&
          !msg.isSelf &&
          msg.timestamp.difference(message.timestamp).abs() <= dedupWindow);
      if (contentMatch >= 0) {
        list[contentMatch] = _mergeMessages(list[contentMatch], message);
        return _scheduleDebouncedSave(normalizedId);
      }
    }

    list.add(message);

    // Memory window overflow. The rows leaving memory are handed to the
    // archive (see [_pendingArchive]) and the save below — which drains them
    // to disk before touching the main file — runs immediately instead of
    // debounced. The previous implementation saved the full list ONCE and
    // then truncated; every later save serialized the truncated list over
    // it, so anything older than the newest 1000 rows was destroyed on disk.
    if (list.length > _maxMessagesInMemory) {
      final overflowCount = list.length - _maxMessagesInMemory;
      _pendingArchive
          .putIfAbsent(normalizedId, () => <ChatMessage>[])
          .addAll(list.sublist(0, overflowCount));
      list.removeRange(0, overflowCount);
      final saveFuture =
          saveHistory(normalizedId, List<ChatMessage>.from(list));
      // Callers may fire-and-forget; awaiting ones still see the error (and
      // saveHistory has already logged it and armed a retry).
      saveFuture.ignore();
      // Make sure any pending debounced save is cancelled — we just wrote
      // the up-to-date state synchronously.
      _appendDebounceTimers.remove(normalizedId)?.cancel();
      _appendFirstDirtyAt.remove(normalizedId);
      final pending = _appendDebouncePending.remove(normalizedId);
      if (pending != null && !pending.isCompleted) {
        // Forward result with an explicit (error, stack) signature so the
        // 2-arg `onError` form is picked. Using `pending.completeError` as a
        // tear-off would silently drop the stack trace (Dart resolves the
        // 1-arg variant), making disk-write failures unhelpful to debug.
        saveFuture.then(
          (_) {
            if (!pending.isCompleted) pending.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!pending.isCompleted) pending.completeError(error, stack);
          },
        );
      }
      return saveFuture;
    }
    return _scheduleDebouncedSave(normalizedId);
  }

  /// Schedule a coalesced disk write for [normalizedId]. Successive calls
  /// inside [_appendDebounce] reset the timer and share the same returned
  /// Future, which completes when the eventual `saveHistory` finishes.
  ///
  /// Callers should pass an already-normalized id.
  Future<void> _scheduleDebouncedSave(String normalizedId) {
    if (_disposed) {
      // Unreachable through appendHistory (it refuses after dispose); kept
      // for absorbDuplicateIds and friends. The session's cache was dropped,
      // so a write now could only put a partial list over the file.
      return Future.value();
    }
    final completer = _appendDebouncePending.putIfAbsent(normalizedId, () {
      // Most appenders fire-and-forget; now that a failed save really fails
      // (GH-7), an unobserved error here must not reach the zone. Awaiting
      // callers still receive it.
      final created = Completer<void>();
      created.future.ignore();
      return created;
    });
    _appendDebounceTimers.remove(normalizedId)?.cancel();
    final firstDirtyAt =
        _appendFirstDirtyAt.putIfAbsent(normalizedId, DateTime.now);
    final untilMaxWait =
        _appendMaxWait - DateTime.now().difference(firstDirtyAt);
    final delay = untilMaxWait < _appendDebounce
        ? (untilMaxWait.isNegative ? Duration.zero : untilMaxWait)
        : _appendDebounce;
    _appendDebounceTimers[normalizedId] = Timer(delay, () {
      _appendDebounceTimers.remove(normalizedId);
      _appendFirstDirtyAt.remove(normalizedId);
      final pending = _appendDebouncePending.remove(normalizedId);
      final save = _resaveCached(normalizedId);
      if (save == null) {
        pending?.complete();
        return;
      }
      save.then(
        (_) => pending?.complete(),
        onError: (Object error, StackTrace? stack) {
          if (pending != null && !pending.isCompleted) {
            pending.completeError(error, stack);
          }
        },
      );
    });
    return completer.future;
  }

  /// Force any pending debounced saves to disk immediately. Intended for
  /// shutdown / logout paths so the very last burst of messages doesn't get
  /// stranded in a not-yet-fired timer.
  Future<void> flushPendingSaves() async {
    // Also conversations whose last write FAILED and wait on a retry timer.
    //
    // #7: loops until no dirty work is left — appends that arrive WHILE this
    // flush awaits schedule new debounce timers that a one-shot snapshot
    // missed. Each conversation is attempted at most once per flush: a save
    // that fails re-arms its retry timer through saveHistory (that timer is
    // left armed, never cancelled here), and the flush then throws a
    // [HistoryFlushException] naming what is still only in memory, instead
    // of returning as if everything were durable.
    final failures = <String, Object>{};
    // Set when the round cap below is reached with dirty work still arriving:
    // that is NOT "flushed", and callers that reset session state on the
    // strength of this future ([rebindHistoryDirectory], [dispose]) would drop
    // rows that live only in memory.
    var exhausted = false;
    const rounds = 16;
    for (var round = 0; round < rounds; round++) {
      final ids = <String>{
        ..._appendDebounceTimers.keys,
        ..._saveRetryTimers.keys,
        ..._dirtyAfterLoad,
        // Overflow rows that are not in the archive file yet. A save drains
        // them on the way (see [_writeMainFile]), but a conversation whose
        // main file was deleted by `clearHistory(keepArchive: true)` has no
        // cached list left to save, so its queued rows were invisible here
        // and dispose dropped them.
        ..._pendingArchive.keys,
      }..removeAll(failures.keys);
      _dirtyAfterLoad.removeAll(ids);
      for (final id in ids) {
        _appendDebounceTimers.remove(id)?.cancel();
        _saveRetryTimers.remove(id)?.cancel();
        _appendFirstDirtyAt.remove(id);
        final pending = _appendDebouncePending.remove(id);
        final save = _resaveCached(id) ?? _drainArchiveOnly(id);
        if (save == null) {
          pending?.complete();
          continue;
        }
        try {
          await save;
          pending?.complete();
        } catch (e, stack) {
          failures[id] = e;
          if (pending != null && !pending.isCompleted) {
            pending.completeError(e, stack);
          }
        }
      }
      // Writes already in flight — the immediate save on a memory-window
      // overflow (which also appends the archive), updateFilePathSafely,
      // archive deletes, loads — are not debounced, so a dispose or a mobile
      // background flush could otherwise return mid-write (and the OS
      // suspend the process there).
      await _awaitFences(_writeFences.values.toList(growable: false));
      final more = <String>{
        ..._appendDebounceTimers.keys,
        ..._saveRetryTimers.keys,
        ..._dirtyAfterLoad,
        for (final entry in _pendingArchive.entries)
          if (entry.value.isNotEmpty) entry.key,
      }..removeAll(failures.keys);
      if (more.isEmpty && _writeFences.isEmpty) break;
      if (round == rounds - 1) {
        exhausted = true;
        for (final id in more) {
          failures.putIfAbsent(
              id,
              () => StateError('still dirty after $rounds flush rounds'));
        }
      }
    }
    if (failures.isNotEmpty) {
      throw HistoryFlushException(failures);
    }
    if (exhausted) {
      // Dirty work kept arriving (or write fences kept being re-armed) for
      // every round. Nothing is known to be lost, but the caller must not
      // treat this as "everything is durable" and reset session state on it.
      throw HistoryFlushException({
        '<still-settling>':
            StateError('flush did not settle in $rounds rounds; no '
                'conversation is known to be unwritten'),
      });
    }
  }

  static Future<void> _awaitFences(List<Future<void>> fences) async {
    for (final fence in fences) {
      try {
        await fence;
      } catch (_) {
        // Fences complete normally; a failed write is already logged.
      }
    }
  }

  /// Tear down the persistence service.
  ///
  /// Awaits [flushPendingSaves] first so any in-flight debounced batch lands
  /// on disk before the timers are cancelled — otherwise teardown paths that
  /// forget to call `flushPendingSaves()` themselves would silently drop the
  /// last burst of messages. Idempotent: a caller that has already awaited
  /// `flushPendingSaves()` will see an empty debounce map and skip straight
  /// to the cancel/clear pass.
  ///
  /// A flush that could not make everything durable is logged at error level
  /// with what is lost; dispose itself does not throw (teardown must finish),
  /// and it cannot keep retrying either: the account may be deleted right
  /// after, and a late retry would recreate its files.
  ///
  /// #23: dispose ends the SESSION, not the object. All session state is
  /// dropped and in-flight loads / archive reads are invalidated, so an
  /// [openSession] on the same object (a service re-init after logout)
  /// starts clean instead of inheriting the previous session's tombstones,
  /// queued archive rows, caches and a permanently "disposed" flag.
  Future<void> dispose() async {
    try {
      await flushPendingSaves();
    } on HistoryFlushException catch (e, st) {
      _logger?.logError(
        '[MessageHistoryPersistence] dispose: ${e.conversationIds.length} '
        'conversation(s) could not be written; their newest rows are lost',
        e,
        st,
      );
    }
    _disposed = true;
    final unarchived =
        _pendingArchive.values.fold<int>(0, (n, rows) => n + rows.length);
    if (unarchived > 0) {
      _logger?.logWarning(
        '[MessageHistoryPersistence] dispose: $unarchived row(s) queued for '
        'the archive were never written',
      );
    }
    _resetSessionState();
  }

  /// Drop every piece of session state and invalidate in-flight work.
  void _resetSessionState() {
    _epoch++;
    for (final timer in _appendDebounceTimers.values) {
      timer.cancel();
    }
    _appendDebounceTimers.clear();
    for (final timer in _saveRetryTimers.values) {
      timer.cancel();
    }
    _saveRetryTimers.clear();
    _saveRetryAttempts.clear();
    _appendFirstDirtyAt.clear();
    for (final completer in _appendDebouncePending.values) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _appendDebouncePending.clear();
    _historyById.clear();
    _recentlyDeleted.clear();
    _pendingArchive.clear();
    _archiveCacheId = null;
    _archiveCacheRows = null;
    _lastViewTimestampById.clear();
    _dirtyAfterLoad.clear();
  }

  /// Whether [msg] is identified by [id] — either its current primary
  /// [ChatMessage.msgID] or a cross-path duplicate id it absorbed during
  /// content dedup ([ChatMessage.altMsgIds]). Every exact-id lookup in this
  /// class routes through here so a dropped hybrid-path id stays resolvable.
  bool _idMatches(ChatMessage msg, String id) =>
      msg.msgID == id || msg.altMsgIds.contains(id);

  /// Every identity a row answers to: its primary id (or, for a pre-msgID
  /// legacy row, the `<millis>_<sender>` key) plus every absorbed alias.
  static List<String> identitiesOf(ChatMessage m) => <String>[
        m.msgID ?? '${m.timestamp.millisecondsSinceEpoch}_${m.fromUserId}',
        ...m.altMsgIds,
      ];

  /// Collapse rows read from disk that are one logical message (#5): the
  /// same primary id (either direction, as before), or a shared identity —
  /// primary or alias — between rows of the same direction (the direction
  /// guard mirrors [appendHistory]: an inbound row and our own row share a
  /// group alias only when one harness sees both ends). Returns rows in
  /// first-seen order; each winner carries the union of all merged ids.
  static List<ChatMessage> _dedupeByIdentity(Iterable<ChatMessage> rows) {
    final slots = <ChatMessage?>[];
    final redirect = <int, int>{};
    final byPrimary = <String, int>{};
    final byIdentity = <String, int>{};
    int resolve(int index) {
      var i = index;
      while (redirect.containsKey(i)) {
        i = redirect[i]!;
      }
      return i;
    }

    void register(ChatMessage m, int index) {
      byPrimary[identitiesOf(m).first] = index;
      for (final id in identitiesOf(m)) {
        byIdentity['${m.isSelf}|$id'] = index;
      }
    }

    for (final msg in rows) {
      final hits = <int>{};
      final primaryHit = byPrimary[identitiesOf(msg).first];
      if (primaryHit != null) hits.add(resolve(primaryHit));
      for (final id in identitiesOf(msg)) {
        final hit = byIdentity['${msg.isSelf}|$id'];
        if (hit != null) hits.add(resolve(hit));
      }
      if (hits.isEmpty) {
        slots.add(msg);
        register(msg, slots.length - 1);
        continue;
      }
      final ordered = hits.toList()..sort();
      final target = ordered.first;
      var merged = slots[target]!;
      final consumed = <ChatMessage>[merged];
      for (final index in ordered.skip(1)) {
        final other = slots[index]!;
        merged = _preferLoadedCopy(merged, other);
        consumed.add(other);
        slots[index] = null;
        redirect[index] = target;
      }
      merged = _preferLoadedCopy(merged, msg);
      consumed.add(msg);
      slots[target] = merged;
      for (final row in consumed) {
        register(row, target);
      }
      register(merged, target);
    }
    return slots.whereType<ChatMessage>().toList();
  }

  /// Which of two on-disk copies of one message to keep: the one with a
  /// final (non-temp) file path, else the newer one; an `action` kind on
  /// either side sticks. The winner keeps every real id of both copies and
  /// the union of their delivery / read state.
  static ChatMessage _preferLoadedCopy(ChatMessage existing, ChatMessage msg) {
    ChatMessage winner;
    if (existing.msgID == null && msg.msgID == null) {
      // Legacy id-less rows keyed on `<millis>_<sender>`: last one wins.
      winner = msg;
    } else if (msg.isTempPath && !existing.isTempPath) {
      winner = existing;
    } else if (!msg.isTempPath && existing.isTempPath) {
      winner = msg;
    } else {
      winner = msg.timestamp.isAfter(existing.timestamp) ? msg : existing;
    }
    final isAction = existing.contentKind == ChatMessageContentKind.action ||
        msg.contentKind == ChatMessageContentKind.action;
    final ids = <String>{
      if (existing.msgID != null) existing.msgID!,
      ...existing.altMsgIds,
      if (msg.msgID != null) msg.msgID!,
      ...msg.altMsgIds,
    }..remove(winner.msgID);
    final aliases = ids.toList()..sort();
    final sameAliases = aliases.length == winner.altMsgIds.length &&
        winner.altMsgIds.toSet().containsAll(aliases);
    final isReceived = existing.isReceived || msg.isReceived;
    final isRead = existing.isRead || msg.isRead;
    final needReadReceipt = existing.needReadReceipt || msg.needReadReceipt;
    if (sameAliases &&
        isReceived == winner.isReceived &&
        isRead == winner.isRead &&
        needReadReceipt == winner.needReadReceipt &&
        (!isAction || winner.contentKind == ChatMessageContentKind.action)) {
      return winner;
    }
    return winner.copyWith(
      altMsgIds: aliases,
      isReceived: isReceived,
      isRead: isRead,
      needReadReceipt: needReadReceipt,
      contentKind: isAction ? ChatMessageContentKind.action : null,
      cloudCustomData: winner.cloudCustomData ??
          (identical(winner, msg)
              ? existing.cloudCustomData
              : msg.cloudCustomData),
    );
  }

  /// Records every id [duplicate] carries (primary + aliases) as an alias of
  /// the cached row [row] — the one a caller's own duplicate check matched —
  /// so the dropped copy's id keeps resolving (delete / markRead / revoke by
  /// the id UIKit holds). Only ids are absorbed; the row's primary id and
  /// state are left alone. Returns the pending save (completes immediately
  /// when there was nothing new to record).
  Future<void> absorbDuplicateIds(
    String conversationId,
    ChatMessage row,
    ChatMessage duplicate,
  ) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final list = _historyById[normalizedId];
    if (list == null) return Future.value();
    final rowId = row.msgID;
    final index = list.indexWhere(
        (m) => identical(m, row) || (rowId != null && _idMatches(m, rowId)));
    if (index < 0) return Future.value();
    final current = list[index];
    final newIds = <String>{
      if (duplicate.msgID != null) duplicate.msgID!,
      ...duplicate.altMsgIds,
    }..removeWhere((id) => _idMatches(current, id));
    if (newIds.isEmpty) return Future.value();
    list[index] = current.copyWith(
      altMsgIds: ({...current.altMsgIds, ...newIds}.toList()..sort()),
    );
    return _scheduleDebouncedSave(normalizedId);
  }

  /// Intelligently merge two messages that resolve to the same logical message
  /// (matched by msgID, an absorbed alias, or the content-dedup heuristic).
  ///
  /// Prefers final file paths over temporary paths, and preserves the best
  /// state. CRITICAL: the result keeps `updated.msgID ?? existing.msgID` as its
  /// primary id, and records EVERY other id the two copies carried (the other
  /// primary + both altMsgIds sets) in [ChatMessage.altMsgIds]. This is what
  /// keeps a cross-path duplicate's dropped id resolvable: whichever id loses
  /// the primary slot is retained as an alias, even across a later merge that
  /// flips the primary. The alias set lives on the row, so it persists and
  /// reloads with the message (no external map to desync after a restart).
  ChatMessage _mergeMessages(ChatMessage existing, ChatMessage updated) {
    // Prefer final path over temp path
    final filePath = updated.isTempPath && !existing.isTempPath
        ? existing.filePath
        : (!updated.isTempPath ? updated.filePath : existing.filePath);

    // Merge file metadata
    final fileSize = updated.fileSize ?? existing.fileSize;
    final mimeType = updated.mimeType ?? existing.mimeType;
    final fileHash = updated.fileHash ?? existing.fileHash;

    // Merge states: both must be pending for result to be pending
    final isPending = updated.isPending && existing.isPending;
    // Either received means received
    final isReceived = updated.isReceived || existing.isReceived;
    // Either read means read
    final isRead = updated.isRead || existing.isRead;

    final mergedMsgID = updated.msgID ?? existing.msgID;
    // Union every id either copy carried, minus the one that becomes primary,
    // minus nulls. Sorted for deterministic on-disk output. When both copies
    // share the same id (the common file_request/file_done merge) this stays
    // empty — only genuine cross-path duplicates accumulate aliases.
    final aliasIds = <String>{
      ...existing.altMsgIds,
      ...updated.altMsgIds,
      if (existing.msgID != null) existing.msgID!,
      if (updated.msgID != null) updated.msgID!,
    }..removeWhere((id) => id == mergedMsgID);
    final altMsgIds = aliasIds.toList()..sort();

    return ChatMessage(
      text: updated.text.isNotEmpty ? updated.text : existing.text,
      fromUserId: updated.fromUserId,
      isSelf: updated.isSelf,
      timestamp: updated.timestamp.isAfter(existing.timestamp)
          ? updated.timestamp
          : existing.timestamp,
      groupId: updated.groupId ?? existing.groupId,
      filePath: filePath,
      fileName: updated.fileName ?? existing.fileName,
      mediaKind: updated.mediaKind ?? existing.mediaKind,
      contentKind: updated.contentKind == ChatMessageContentKind.action ||
              existing.contentKind == ChatMessageContentKind.action
          ? ChatMessageContentKind.action
          : ChatMessageContentKind.normal,
      isPending: isPending,
      isReceived: isReceived,
      isRead: isRead,
      msgID: mergedMsgID,
      version: updated.version,
      fileSize: fileSize,
      mimeType: mimeType,
      fileHash: fileHash,
      altMsgIds: altMsgIds,
      // S17/S18 reply/forward quote. toxee's hybrid runtime double-writes an
      // outbound send through both paths with different msgIDs, which merge
      // here — and only ONE copy carries the sender-side cloudCustomData
      // (FfiChatService.sendText sets it; the binary-replacement copy does
      // not). Preferring whichever copy has it keeps the quote from being
      // erased by the merge. Without this, the persisted reply loses its
      // messageReply metadata even though sendText set it (L3-reply-text).
      cloudCustomData: updated.cloudCustomData ?? existing.cloudCustomData,
      // Read-receipt intent: like cloudCustomData, only ONE cross-path copy
      // carries it (the FfiChatService send sets it; the binary-replacement
      // copy does not) — either copy having asked for receipts wins.
      needReadReceipt: updated.needReadReceipt || existing.needReadReceipt,
    );
  }

  /// Get message history for a conversation (from memory cache)
  ///
  /// Returns the cached messages. If not in cache, returns empty list.
  /// Use loadHistory() to load from disk if needed.
  ///
  /// [conversationId] - Will be normalized before lookup
  List<ChatMessage> getHistory(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    return List<ChatMessage>.from(_historyById[normalizedId] ?? []);
  }

  /// Check if history file exists for a conversation
  /// Returns true if the file exists, false otherwise
  ///
  /// [conversationId] - Will be normalized before check
  Future<bool> historyFileExists(String conversationId) async {
    try {
      final normalizedId = ConversationIdUtils.normalize(conversationId);
      final file = await _getHistoryFile(normalizedId);
      return await file.exists();
    } catch (e) {
      return false;
    }
  }

  /// Get all conversation IDs that have history IN MEMORY. A conversation
  /// that only has archived rows is not listed; see
  /// [getArchivedConversationIds].
  Set<String> getConversationIds() {
    return _historyById.keys.toSet();
  }

  /// Clear history for a specific conversation
  /// This deletes the JSON history file but does NOT delete actual media files
  /// (images, videos, audio, documents) referenced in the messages
  ///
  /// Also clears all cache entries that might match this conversation ID
  /// (e.g., original ID and normalized ID variants)
  ///
  /// CRITICAL: This method scans all history files to find and delete any file
  /// that contains messages for this conversation, even if the filename doesn't match
  /// (e.g., due to ID normalization or sanitization differences)
  ///
  /// [conversationId] - Will be normalized before clearing
  ///
  /// [keepArchive] - keep rows older than the in-memory window. Only for the
  /// "last in-memory row was deleted" case; clearing a conversation drops them.
  Future<void> clearHistory(String conversationId,
      {bool keepArchive = false}) async {
    // Normalize conversationId for comparison
    final normalizedConversationId =
        ConversationIdUtils.normalize(conversationId);

    // Cancel any in-flight debounced saves for this conversation — otherwise
    // a queued save could resurrect the in-memory list we are about to clear.
    _appendDebounceTimers.remove(conversationId)?.cancel();
    _appendDebounceTimers.remove(normalizedConversationId)?.cancel();
    _saveRetryTimers.remove(conversationId)?.cancel();
    _saveRetryTimers.remove(normalizedConversationId)?.cancel();
    _saveRetryAttempts.remove(conversationId);
    _saveRetryAttempts.remove(normalizedConversationId);
    _appendFirstDirtyAt.remove(conversationId);
    _appendFirstDirtyAt.remove(normalizedConversationId);
    final pendingDirect = _appendDebouncePending.remove(conversationId);
    if (pendingDirect != null && !pendingDirect.isCompleted) {
      pendingDirect.complete();
    }
    final pendingNormalized =
        _appendDebouncePending.remove(normalizedConversationId);
    if (pendingNormalized != null && !pendingNormalized.isCompleted) {
      pendingNormalized.complete();
    }

    // Clear in-memory cache for this ID and all variants
    _historyById.remove(conversationId);

    // Also clear any cache entries that might match this conversation
    // (e.g., if there are multiple ID variants stored)
    final keysToRemove = <String>[];
    for (final key in _historyById.keys) {
      // Normalize key for comparison
      final normalizedKey = ConversationIdUtils.normalize(key);

      // Check if key matches conversationId using normalized comparison
      if (ConversationIdUtils.equals(key, conversationId) ||
          ConversationIdUtils.equals(normalizedKey, normalizedConversationId)) {
        keysToRemove.add(key);
      }
    }
    for (final key in keysToRemove) {
      _historyById.remove(key);
    }

    // Pre #3: invalidate every operation queued for this conversation BEFORE
    // now. A load started before the clear used to install the old rows
    // after the clear completed (and schedule a save of them); a save
    // snapshot taken before it used to rewrite the file. Both now see a
    // stale generation and do nothing. The file is gone below, so the
    // tombstones (deletes not yet on disk) have nothing left to guard.
    for (final id in <String>{normalizedConversationId, conversationId}) {
      _conversationGen[id] = (_conversationGen[id] ?? 0) + 1;
      _recentlyDeleted.remove(id);
      _dirtyAfterLoad.remove(id);
    }
    if (!keepArchive) {
      _pendingArchive.remove(normalizedConversationId);
      _pendingArchive.remove(conversationId);
    }
    if (_archiveCacheId == normalizedConversationId ||
        _archiveCacheId == conversationId) {
      _archiveCacheId = null;
      _archiveCacheRows = null;
    }

    // The delete runs under the conversation lock: a write already running
    // (a debounced save whose timer fired, mid rename with a pre-clear
    // snapshot) finishes first and is then deleted; everything queued after
    // this clear runs after the delete. A later incoming message is a
    // legitimate new conversation.
    //
    // H7: filenames are deterministic — `_getHistoryFile` derives them from
    // `ConversationIdUtils.normalize` + `sanitizeForFilename`, so no
    // directory scan is needed.
    await _serialized(normalizedConversationId, () async {
      if (keepArchive) {
        // BEFORE the main file goes. Rows pushed out of the memory window are
        // durable only once the archive holds them, and until then the MAIN
        // FILE is the copy that still has them (a save that cannot append the
        // archive aborts its own rewrite, precisely to keep that invariant).
        // Draining afterwards and swallowing the failure deleted the last
        // copy of those rows: nothing else drains `_pendingArchive` for a
        // conversation with no cached list, and dispose only counts them.
        // A failure now leaves the rows queued, the main file intact and the
        // flush path ([flushPendingSaves]) owing the write — and propagates,
        // so the caller does not report a delete it did not perform.
        await _drainPendingArchive(
            normalizedConversationId, await _resolveStorageRoots());
      }
      try {
        final file = await _getHistoryFile(normalizedConversationId);
        try {
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {
          // Best-effort; memory cache is already cleared above.
        }
        // Also drop any backup file we may have left around.
        try {
          final backup = await _getBackupFile(normalizedConversationId);
          if (await backup.exists()) {
            await backup.delete();
          }
        } catch (_) {}
        if (!keepArchive) {
          await _deleteArchive(normalizedConversationId);
        }
      } catch (e) {
        // Log error but don't throw - clearing should continue
        // The file may not exist or may be locked, but we've cleared memory cache
      }
    });
  }

  /// Clear all message histories
  Future<void> clearAllHistories() async {
    // Cancel any in-flight debounced saves so they don't recreate files we
    // are about to delete.
    //
    // #8: this used to cancel timers and delete the directory while loads
    // and writes were still in flight, and kept tombstones, timestamps and
    // dirty flags: a pending rename recreated a deleted file, and a load
    // reinstalled old rows. Now: invalidate everything in flight (epoch),
    // drop ALL state, raise a barrier so work queued from here on waits for
    // the delete, wait for work already running, then delete.
    _resetSessionState();
    final inFlight = _writeFences.values.toList(growable: false);
    final barrier = Completer<void>();
    final previousBarrier = _clearAllBarrier;
    _clearAllBarrier = barrier.future;
    try {
      if (previousBarrier != null) await previousBarrier;
      await _awaitFences(inFlight);
      final historyDir = await _getHistoryDirectory();
      if (await historyDir.exists()) {
        await historyDir.delete(recursive: true);
      }
    } catch (e, st) {
      _logger?.logError(
          '[MessageHistoryPersistence] clearAllHistories failed', e, st);
    } finally {
      // The owner marker went with the directory; resolve again next time.
      _resolvedDefaultDirPath = null;
      barrier.complete();
      if (identical(_clearAllBarrier, barrier.future)) {
        _clearAllBarrier = null;
      }
    }
  }

  /// Update a message in the history
  ///
  /// Finds the message by msgID and updates it, then saves to disk.
  ///
  /// [conversationId] - Will be normalized before update
  Future<bool> updateMessage(
      String conversationId, String msgID, ChatMessage updatedMessage) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final list = _historyById[normalizedId];
    if (list == null) return false;

    final index = list.indexWhere((msg) => _idMatches(msg, msgID));
    if (index == -1) return false;

    // Merge intelligently instead of direct replacement
    final existing = list[index];
    final merged = _mergeMessages(existing, updatedMessage);
    list[index] = merged;
    await saveHistory(normalizedId, list);
    return true;
  }

  /// Safely update file path for a message
  ///
  /// This method ensures atomic file path updates with integrity checks:
  /// 1. Verifies the new file exists (refuses the update otherwise unless
  ///    [allowMissing] is set)
  /// 2. Gets file metadata (size, etc.)
  /// 3. Updates the message atomically
  /// 4. Optionally deletes the old temporary file after successful update
  ///
  /// [conversationId] - Will be normalized before update
  /// [msgID] - Message ID to update
  /// [newFilePath] - New file path (must exist unless [allowMissing] is true)
  /// [deleteOldTempFile] - Whether to delete old temp file after successful update
  /// [allowMissing] - Opt into the legacy behavior of repointing history at a
  ///   path that does not exist yet (the old temp file is never deleted in
  ///   that case). Defaults to false, which refuses the update.
  ///
  /// Returns true if update was successful, false otherwise.
  Future<bool> updateFilePathSafely(
    String conversationId,
    String msgID,
    String newFilePath, {
    bool deleteOldTempFile = true,
    bool allowMissing = false,
  }) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final list = _historyById[normalizedId];
    if (list == null) return false;

    final index = list.indexWhere((msg) => _idMatches(msg, msgID));
    if (index == -1) return false;

    final existing = list[index];
    final oldFilePath = existing.filePath;

    // 1. Verify the new file exists. CR-06: the documented contract is that
    // the new path must exist; refuse to repoint history at a dangling path
    // (and do NOT delete the old temp below) unless the caller explicitly
    // opts into the compatibility behavior via [allowMissing].
    final newFile = File(newFilePath);
    final newFileExists = await newFile.exists();
    if (!newFileExists && !allowMissing) {
      return false;
    }

    // 2. Get file metadata if the file exists.
    int? fileSize;
    if (newFileExists) {
      try {
        fileSize = await newFile.length();
      } catch (e) {
        // Ignore errors getting file size.
      }
    }

    // 3. Create updated message
    final updated = existing.copyWith(
      filePath: newFilePath,
      fileSize: fileSize,
    );

    // 4. Update message atomically. M4: the previous "verify by re-reading
    // the same in-memory list we just wrote into" was dead code (the check
    // could never trip) and swallowed real disk-write failures. Wrap the
    // save in try/catch instead so an actual `saveHistory` exception is
    // surfaced to the caller and the in-memory mutation gets reverted.
    // The awaits above let appends (and the memory-window trim) or deletes
    // move rows: locate the row again by identity instead of reusing index.
    final liveIndex = list.indexWhere((msg) => identical(msg, existing));
    if (liveIndex == -1) return false; // deleted or trimmed meanwhile
    list[liveIndex] = updated;
    try {
      await saveHistory(normalizedId, list);
    } catch (_) {
      final rollbackIndex = list.indexWhere((msg) => identical(msg, updated));
      if (rollbackIndex != -1) list[rollbackIndex] = existing;
      return false;
    }

    // 5. Delete old temp file if requested and update was successful. CR-06:
    // never delete the old temp when the new file is missing, or we'd lose
    // both files (the legacy [allowMissing] path can repoint to a dangling
    // path that may never materialize).
    if (deleteOldTempFile &&
        newFileExists &&
        oldFilePath != null &&
        existing.isTempPath) {
      // Delay deletion to ensure update is persisted
      Future.delayed(Duration(seconds: 5), () async {
        try {
          final oldFile = File(oldFilePath);
          if (await oldFile.exists()) {
            await oldFile.delete();
          }
        } catch (e) {
          // Ignore deletion errors - file might be in use or already deleted
        }
      });
    }

    return true;
  }

  /// Remove a message from the history
  ///
  /// Finds the message by msgID and removes it, then saves to disk.
  ///
  /// [conversationId] - Will be normalized before removal
  ///
  /// Removing the sole row persists an empty conversation (see
  /// [saveHistory]). A row that is not in memory — older than the window,
  /// or in a conversation that only has an archive left — is removed from
  /// the archive (#21), by every identity it carries.
  ///
  /// A row found IN MEMORY is deleted from the archive too. A crash between
  /// an archive append and the main-file rewrite leaves the same row in both
  /// files; deleting only the in-memory copy left the archived one behind, and
  /// once the tombstone cleared it came back as history the user had deleted.
  Future<bool> removeMessage(String conversationId, String msgID) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final list = _historyById[normalizedId];
    if (list != null) {
      final removed = list.where((msg) => _idMatches(msg, msgID)).toList();
      if (removed.isNotEmpty) {
        list.removeWhere((msg) => _idMatches(msg, msgID));
        noteRemovedFromCache(normalizedId, removed);
        await saveHistory(normalizedId, list);
        await _removeArchivedRows(normalizedId, <String>{
          msgID,
          for (final row in removed) ...identitiesOf(row),
        });
        return true;
      }
    }
    final archived = await _removeArchivedRows(normalizedId, {msgID});
    if (archived.isEmpty) return false;
    // A crash between an archive append and the main-file rewrite can leave
    // the row in the main file too; keep a later load from reinstalling it.
    noteRemovedFromCache(normalizedId, archived);
    return true;
  }

  /// Get the in-memory cache (for direct access if needed)
  Map<String, List<ChatMessage>> get cache => Map.unmodifiable(_historyById);

  /// Set the in-memory cache (for initialization)
  void setCache(Map<String, List<ChatMessage>> cache) {
    _historyById.clear();
    _historyById.addAll(cache);
  }

  /// Replace the in-memory cached history for a single conversation.
  ///
  /// Used by mutating operations (e.g. message deletion) whose owner keeps a
  /// parallel list and wants the persistence cache to stay in sync so that
  /// subsequent `getHistory(id)` reads do not return stale data. Does not
  /// touch disk; pair with `saveHistory` when persistence is also required.
  ///
  /// [conversationId] - Will be normalized before use.
  void setCachedHistory(String conversationId, List<ChatMessage> messages) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    if (messages.isEmpty) {
      _historyById.remove(normalizedId);
    } else {
      _historyById[normalizedId] = List<ChatMessage>.from(messages);
    }
  }

  // ---- Single-source-of-truth cache accessors (X4 consolidation) ----
  //
  // The previous design kept a parallel `_historyByIdInternal` map inside
  // `FfiChatService` and lazily merged from `_historyById` here, which let the
  // two drift (e.g. `_handleFileDone` mutated the FfiChatService list by index
  // and only `_saveHistory`'d that one — the persistence cache never saw the
  // update). These accessors expose the persistence map as the only writable
  // in-memory store so FfiChatService can act as a thin client over it.

  /// Lookup the cached list for [conversationId] WITHOUT defensive copy.
  ///
  /// Returns the mutable internal list (or null if absent). Callers may mutate
  /// elements in place (e.g. `list[i] = updated`) and the mutations are
  /// observable through subsequent [getHistory] / [cache] reads. After a
  /// mutation, the caller is responsible for arranging persistence via
  /// [saveHistory] (or [appendHistory] for new tail entries).
  ///
  /// Pure reads that want a defensive copy should keep using [getHistory].
  ///
  /// [conversationId] - Will be normalized before lookup.
  List<ChatMessage>? getCachedList(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    return _historyById[normalizedId];
  }

  /// Lookup the cached list for [conversationId], creating an empty list if
  /// it does not yet exist. Returns the mutable internal list.
  ///
  /// Like [getCachedList], element mutations are observable downstream and the
  /// caller is responsible for persistence.
  ///
  /// [conversationId] - Will be normalized before use.
  List<ChatMessage> ensureCachedList(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    return _historyById.putIfAbsent(normalizedId, () => <ChatMessage>[]);
  }

  /// Replace a single message in the cached list at [index]. No-op if the
  /// conversation is not cached or the index is out of range.
  ///
  /// Does not touch disk — callers needing persistence should follow up with
  /// [saveHistory] (or use [updateMessage] for the merge-aware path).
  ///
  /// [conversationId] - Will be normalized before lookup.
  void replaceInCache(String conversationId, int index, ChatMessage message) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final list = _historyById[normalizedId];
    if (list == null || index < 0 || index >= list.length) return;
    list[index] = message;
  }

  /// Remove the cached list for [conversationId]. Does not delete the on-disk
  /// file — use [clearHistory] for the full clear semantics.
  ///
  /// [conversationId] - Will be normalized before removal.
  void removeCachedHistory(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    _historyById.remove(normalizedId);
    // Also strip exact-match (un-normalized) variant to mirror legacy
    // FfiChatService behaviour for ids that fail the equals check.
    _historyById.remove(conversationId);
  }

  /// Clear ALL in-memory cached histories. Does not touch disk.
  ///
  /// Used by FfiChatService.dispose() to release per-account state without
  /// disturbing the persisted JSON files (which are wiped via
  /// [clearAllHistories] only on explicit account deletion).
  void clearAllCached() {
    _historyById.clear();
  }

  /// Update the last view timestamp for a conversation
  ///
  /// Updates the timestamp when the user last viewed the conversation.
  /// This is used to calculate unread message count.
  ///
  /// [conversationId] - Will be normalized before update
  Future<void> updateLastViewTimestamp(
      String conversationId, int timestamp) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    _lastViewTimestampById[normalizedId] = timestamp;
    // Save the updated history to persist the new timestamp
    final messages = _historyById[normalizedId];
    if (messages != null && messages.isNotEmpty) {
      await _saveViewState(normalizedId, messages);
    }
  }

  /// Saves read-state / view-barrier changes. A failure is already logged and
  /// retried by [saveHistory] (the state stays in memory), and none of the
  /// view-state callers can do anything useful with it, most of them fire and
  /// forget, so it is absorbed here rather than surfacing as a zone error.
  Future<void> _saveViewState(
      String normalizedId, List<ChatMessage> messages) async {
    try {
      await saveHistory(normalizedId, messages);
    } catch (_) {
      // Logged + retry armed in saveHistory.
    }
  }

  /// Get the last view timestamp for a conversation
  ///
  /// Returns the timestamp when the user last viewed the conversation.
  /// Returns 0 if the conversation has never been viewed.
  ///
  /// [conversationId] - Will be normalized before lookup
  int getLastViewTimestamp(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    return _lastViewTimestampById[normalizedId] ?? 0;
  }

  /// Get the unread message count for a conversation
  ///
  /// Calculates the number of unread messages based on:
  /// - Messages with timestamp > lastViewTimestamp
  /// - Messages that are not self-sent (!isSelf)
  /// - Messages that are not marked as read (!isRead)
  ///
  /// TODO(time-drift): `lastViewTimestamp` is written using `DateTime.now()`
  /// on the local device but compared against `msg.timestamp`, which often
  /// originates from the remote peer's clock. System-clock rollback or large
  /// cross-device skew can either inflate the unread count (already-seen
  /// messages re-counted) or zero it out (new messages stamped earlier than
  /// the local clock). The right fix is to anchor `lastViewTimestamp` to the
  /// highest message timestamp in the conversation at view-time, or to also
  /// persist a read-msgID set. `setActivePeer` now calls
  /// [markConversationViewed], which anchors the barrier to the max message
  /// timestamp (the wall-clock path remains on the legacy
  /// `updateLastViewTimestamp` for any external callers).
  ///
  /// [conversationId] - Will be normalized before lookup
  int getUnreadCount(String conversationId) {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final messages = _historyById[normalizedId];
    if (messages == null || messages.isEmpty) {
      return 0;
    }

    int count = 0;

    for (final msg in messages) {
      // isRead is authoritative: markConversationViewed flags every message
      // present at view-time, loadHistory reconciles persisted history against
      // the view barrier, and new arrivals come in unread. Counting `!isRead`
      // (rather than the old strict `ts > lastView`) means a same-millisecond
      // or clock-skewed arrival — timestamp <= the barrier yet genuinely new —
      // is still counted instead of being silently dropped.
      if (!msg.isSelf && !msg.isRead) {
        count++;
      }
    }

    return count;
  }

  /// Mark all unread messages as read for a conversation
  ///
  /// Marks all messages with timestamp > lastViewTimestamp and !isSelf as read.
  /// This is called when the user opens a conversation.
  ///
  /// [conversationId] - Will be normalized before update
  Future<void> markUnreadMessagesAsRead(String conversationId) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    final messages = _historyById[normalizedId];
    if (messages == null || messages.isEmpty) {
      return;
    }

    final lastViewTimestamp = _lastViewTimestampById[normalizedId] ?? 0;
    bool updated = false;

    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final msgTimestamp = msg.timestamp.millisecondsSinceEpoch;
      // Mark messages as read that are:
      // 1. After the last view timestamp
      // 2. Not self-sent
      // 3. Not already marked as read
      if (msgTimestamp > lastViewTimestamp && !msg.isSelf && !msg.isRead) {
        messages[i] = msg.copyWith(isRead: true);
        updated = true;
      }
    }

    if (updated) {
      await _saveViewState(normalizedId, messages);
    }
  }

  /// Mark a conversation as viewed with a clock-drift-immune read barrier.
  ///
  /// Instead of stamping `lastViewTimestamp` with the local wall clock (which
  /// drifts relative to the remote `msg.timestamp` values it is compared
  /// against in [getUnreadCount]), anchor the barrier to the highest message
  /// timestamp currently in the conversation and flag every current non-self
  /// message `isRead`. Messages that arrive afterwards carry a strictly
  /// greater timestamp and are still counted as unread.
  ///
  /// [conversationId] - Will be normalized before use.
  Future<void> markConversationViewed(String conversationId) async {
    final normalizedId = ConversationIdUtils.normalize(conversationId);
    var messages = _historyById[normalizedId];
    // If history exists on disk but isn't loaded into memory yet, load it so
    // the barrier anchors to — and is persisted alongside — the real messages.
    // Without this, viewing an unloaded conversation only stamped an in-memory
    // barrier that was lost on restart (loadHistory would then restore the
    // older on-disk barrier, re-counting already-seen messages as unread).
    if (messages == null) {
      final file = await _getHistoryFile(normalizedId);
      if (await file.exists()) {
        await loadHistory(normalizedId);
        messages = _historyById[normalizedId];
      }
    }
    if (messages == null || messages.isEmpty) {
      // Genuinely empty/new conversation: no messages to anchor to. Stamp an
      // in-memory wall-clock barrier; it is persisted by the next saveHistory
      // once a message arrives, and until then there is nothing to be unread.
      final now = DateTime.now().millisecondsSinceEpoch;
      final prevBarrier = _lastViewTimestampById[normalizedId] ?? 0;
      if (now > prevBarrier) {
        _lastViewTimestampById[normalizedId] = now;
      }
      return;
    }

    int maxTimestamp = _lastViewTimestampById[normalizedId] ?? 0;
    bool updated = false;
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final ts = msg.timestamp.millisecondsSinceEpoch;
      if (ts > maxTimestamp) maxTimestamp = ts;
      if (!msg.isSelf && !msg.isRead) {
        messages[i] = msg.copyWith(isRead: true);
        updated = true;
      }
    }
    final prevBarrier = _lastViewTimestampById[normalizedId] ?? 0;
    if (maxTimestamp > prevBarrier) {
      _lastViewTimestampById[normalizedId] = maxTimestamp;
      updated = true;
    }
    if (updated) {
      await _saveViewState(normalizedId, messages);
    }
  }

  /// Clean up temporary files on startup
  ///
  /// Removes temporary files and old backups that are no longer needed.
  Future<void> cleanupTempFiles() async {
    try {
      final dir = await _getHistoryDirectory();
      if (!await dir.exists()) return;

      final files = dir.listSync();
      final now = DateTime.now();

      for (final fileEntry in files) {
        if (fileEntry is File) {
          try {
            // Clean up temporary files (.tmp)
            if (fileEntry.path.endsWith('.tmp')) {
              final stat = await fileEntry.stat();
              final age = now.difference(stat.modified);
              // Delete temp files older than 1 hour
              if (age.inHours > 1) {
                await fileEntry.delete();
              }
            }

            // Clean up old backup files (.bak) - keep only recent ones
            if (fileEntry.path.endsWith('.bak')) {
              final stat = await fileEntry.stat();
              final age = now.difference(stat.modified);
              // Delete backups older than 7 days
              if (age.inDays > 7) {
                await fileEntry.delete();
              }
            }
          } catch (e) {
            // Continue cleanup even if one file fails
          }
        }
      }
    } catch (e) {
      // Ignore cleanup errors
    }
  }
}

/// Epoch + per-conversation generation captured when an operation is called;
/// see "One concurrency model per conversation" in [MessageHistoryPersistence].
typedef _OpToken = ({int epoch, int gen});

/// [MessageHistoryPersistence.flushPendingSaves] could not write every
/// conversation. Their rows are still in memory and a retry is armed; the
/// flush reports it instead of returning as if everything were durable.
class HistoryFlushException implements Exception {
  HistoryFlushException(this.errors);

  /// Conversation id -> the error its last write attempt failed with.
  final Map<String, Object> errors;

  Iterable<String> get conversationIds => errors.keys;

  @override
  String toString() =>
      'HistoryFlushException: ${errors.length} conversation(s) not written: '
      '${errors.entries.map((e) => '${e.key}: ${e.value}').join('; ')}';
}
