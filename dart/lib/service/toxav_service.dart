/// ToxAV Service.
///
/// Manages ToxAV lifecycle and audio/video frame processing.
///
/// Threading & FFI safety:
/// - The four receive-side trampolines are invoked from native code via
///   `Dart_PostCObject_DL` and execute on the Dart isolate that owns the
///   FFI library handle. Frame buffers (`pcm`, `y`, `u`, `v`) are owned by
///   c-toxcore and MUST NOT be retained past the synchronous trampoline
///   call — they are recycled by the next ToxAV iterate tick. We therefore
///   COPY each buffer into a Dart-owned `Int16List` / `Uint8List` before
///   handing it off to user callbacks. The previous implementation passed
///   `asTypedList` views directly, which was a latent use-after-free when
///   the consumer iterated the data asynchronously (e.g. in a `compute()`
///   isolate or after an `await`).
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart' as pkgffi;
import '../ffi/tim2tox_ffi.dart';
import '../interfaces/logger_service.dart';
import 'call_av_backend.dart';

/// Callback types for audio/video events.
///
/// `pcm`, `y`, `u`, `v` are Dart-owned copies (`Int16List` / `Uint8List`).
/// Consumers may retain or pass them across async boundaries safely.
typedef CallCallback = void Function(
    int friendNumber, bool audioEnabled, bool videoEnabled);
typedef CallStateCallback = void Function(int friendNumber, int state);
typedef AudioReceiveCallback = void Function(int friendNumber, List<int> pcm,
    int sampleCount, int channels, int samplingRate);
typedef VideoReceiveCallback = void Function(int friendNumber, int width,
    int height, List<int> y, List<int> u, List<int> v);

/// Peer-suggested audio bit rate change (toxav_audio_bit_rate_cb).
/// `audioBitRate` is in kbit/sec; 0 means the peer disabled audio.
typedef AudioBitrateChangedCallback = void Function(
    int friendNumber, int audioBitRate);

/// Peer-suggested video bit rate change (toxav_video_bit_rate_cb).
/// `videoBitRate` is in kbit/sec; 0 means the peer disabled video.
typedef VideoBitrateChangedCallback = void Function(
    int friendNumber, int videoBitRate);

// Define callback types for FFI (matching tim2tox_ffi.dart)
typedef _AvCallCallbackNative = ffi.Void Function(
  ffi.Uint32, // friend_number
  ffi.Int32, // audio_enabled
  ffi.Int32, // video_enabled
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _AvCallStateCallbackNative = ffi.Void Function(
  ffi.Uint32, // friend_number
  ffi.Uint32, // state
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _AvAudioReceiveCallbackNative = ffi.Void Function(
  ffi.Uint32, // friend_number
  ffi.Pointer<ffi.Int16>, // pcm
  ffi.Size, // sample_count
  ffi.Uint8, // channels
  ffi.Uint32, // sampling_rate
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _AvVideoReceiveCallbackNative = ffi.Void Function(
  ffi.Uint32, // friend_number
  ffi.Uint16, // width
  ffi.Uint16, // height
  ffi.Pointer<ffi.Uint8>, // y
  ffi.Pointer<ffi.Uint8>, // u
  ffi.Pointer<ffi.Uint8>, // v
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _AvAudioBitrateChangedCallbackNative = ffi.Void Function(
  ffi.Uint32, // friend_number
  ffi.Uint32, // audio_bit_rate
  ffi.Pointer<ffi.Void>, // user_data
);
typedef _AvVideoBitrateChangedCallbackNative = ffi.Void Function(
  ffi.Uint32, // friend_number
  ffi.Uint32, // video_bit_rate
  ffi.Pointer<ffi.Void>, // user_data
);

/// ToxAV Service for managing audio/video calls
class ToxAVService implements CallAvBackend {
  final Tim2ToxFfi _ffi;
  final LoggerService? _logger;
  bool _initialized = false;
  int? _instanceId; // Instance ID for multi-instance routing

  // Global map for instance ID -> ToxAVService routing (for multi-instance support)
  static final Map<int, ToxAVService> _instanceServices = {};

  // Kept for backward compatibility with default instance
  static ToxAVService? _globalService;

  // First-wins logger usable from static trampolines (for early-startup
  // diagnostics before a per-instance lookup succeeds).
  //
  // Last-wins would let a second instance (e.g. an auto_test peer constructed
  // after the primary) overwrite an active logger with one that may be a
  // no-op, silently swallowing errors from the first instance's trampolines.
  // First-wins keeps the earliest non-null logger; production is single-
  // instance so this only matters in multi-peer test scenarios.
  static LoggerService? _staticLogger;

  // Callbacks
  CallCallback? _onCall;
  CallStateCallback? _onCallState;
  AudioReceiveCallback? _onAudioReceive;
  VideoReceiveCallback? _onVideoReceive;
  AudioBitrateChangedCallback? _onAudioBitrateChanged;
  VideoBitrateChangedCallback? _onVideoBitrateChanged;

  ToxAVService(this._ffi, {LoggerService? logger}) : _logger = logger {
    // First-wins: only adopt this logger statically if none has been set yet.
    if (logger != null && _staticLogger == null) {
      _staticLogger = logger;
    }
    try {
      _instanceId = _ffi.getCurrentInstanceId();
      _logger?.logDebug('[ToxAVService] Constructor: instanceId=$_instanceId');

      if (_instanceId != null && _instanceId! != 0) {
        _instanceServices[_instanceId!] = this;
        _logger
            ?.logDebug('[ToxAVService] Registered service for instance $_instanceId');
      } else {
        // Default instance (backward compatibility)
        _globalService = this;
        _logger?.logDebug(
            '[ToxAVService] Registered as global service (default instance)');
      }
    } catch (e, st) {
      _logger?.logError('[ToxAVService] Constructor: failed to get instance ID',
          e, st);
      // Fallback to global service
      _globalService = this;
    }
  }

  /// Dispatches AV call callback from native (posted via SendCallbackToDart from tox thread).
  static void dispatchAvCall(
      int instanceId, int friendNumber, bool audioEnabled, bool videoEnabled) {
    final targetService =
        instanceId != 0 ? _instanceServices[instanceId] : _globalService;
    targetService?._onCall?.call(friendNumber, audioEnabled, videoEnabled);
  }

  /// Dispatches AV call state callback from native (posted via SendCallbackToDart from tox thread).
  static void dispatchAvCallState(int instanceId, int friendNumber, int state) {
    final targetService =
        instanceId != 0 ? _instanceServices[instanceId] : _globalService;
    targetService?._onCallState?.call(friendNumber, state);
  }

  /// Initialize ToxAV
  @override
  Future<bool> initialize() async {
    _logger?.logDebug('[ToxAVService] initialize() called');
    if (_initialized) {
      _logger?.logDebug('[ToxAVService] initialize() already initialized');
      return true;
    }

    try {
      final result = _ffi.avInitialize(_ffi.getCurrentInstanceId());
      _logger?.logDebug('[ToxAVService] initialize() FFI result: $result');
      if (result == 1) {
        _initialized = true;
        _setupCallbacks();
        _logger?.log('[ToxAVService] initialize() succeeded');
        return true;
      }
      _logger?.logWarning(
          '[ToxAVService] initialize() failed: FFI returned $result');
      return false;
    } catch (e, st) {
      _logger?.logError('[ToxAVService] initialize() exception', e, st);
      return false;
    }
  }

  /// Shutdown ToxAV
  void shutdown() {
    _logger?.logDebug('[ToxAVService] shutdown() called');
    if (!_initialized) {
      _logger?.logDebug('[ToxAVService] shutdown() not initialized, skipping');
      return;
    }
    _ffi.avShutdown(_ffi.getCurrentInstanceId());
    _initialized = false;

    if (_instanceId != null && _instanceId! != 0) {
      _instanceServices.remove(_instanceId!);
      _logger?.logDebug(
          '[ToxAVService] Unregistered service for instance $_instanceId');
    } else {
      if (_globalService == this) {
        _globalService = null;
        _logger?.logDebug('[ToxAVService] Unregistered global service');
      }
    }

    _logger?.log('[ToxAVService] shutdown() completed');
  }

  /// Setup callbacks
  void _setupCallbacks() {
    final instanceId = _instanceId ?? 0;
    _logger?.logDebug('[ToxAVService] _setupCallbacks() instanceId=$instanceId');

    // Allocate memory for instance ID (will be passed as user_data).
    //
    // **Accepted-tradeoff leak.** This 8-byte block is intentionally never
    // freed for the lifetime of the process. Freeing it during `shutdown()`
    // is unsafe because c-toxcore may still hold the pointer and dispatch a
    // final tail-event after `avShutdown()` returns; there is no exposed
    // "callbacks-quiesced" signal we could wait on. Practical cost: one
    // 8-byte allocation per `_setupCallbacks()` invocation (i.e. per
    // re-initialize after a logout/login that uses ToxAV). At single-digit
    // re-inits per day this is negligible (~bytes/day) and bounded by
    // process lifetime. Do NOT add a "smart" cleanup — that was tried and
    // produced use-after-free crashes when tail events landed.
    final instanceIdPtr = pkgffi.malloc<ffi.Int64>();
    instanceIdPtr.value = instanceId;

    final onCallNative = ffi.Pointer.fromFunction<_AvCallCallbackNative>(
      _onCallNativeTrampoline,
    );
    final onCallStateNative =
        ffi.Pointer.fromFunction<_AvCallStateCallbackNative>(
      _onCallStateNativeTrampoline,
    );
    final onAudioReceiveNative =
        ffi.Pointer.fromFunction<_AvAudioReceiveCallbackNative>(
      _onAudioReceiveNativeTrampoline,
    );
    final onVideoReceiveNative =
        ffi.Pointer.fromFunction<_AvVideoReceiveCallbackNative>(
      _onVideoReceiveNativeTrampoline,
    );
    final onAudioBitrateNative =
        ffi.Pointer.fromFunction<_AvAudioBitrateChangedCallbackNative>(
      _onAudioBitrateNativeTrampoline,
    );
    final onVideoBitrateNative =
        ffi.Pointer.fromFunction<_AvVideoBitrateChangedCallbackNative>(
      _onVideoBitrateNativeTrampoline,
    );

    final instanceIdForFfi = _instanceId ?? _ffi.getCurrentInstanceId();
    _ffi.avSetCallCallbackNative(
        instanceIdForFfi, onCallNative.cast(), instanceIdPtr.cast());
    _ffi.avSetCallStateCallbackNative(
        instanceIdForFfi, onCallStateNative.cast(), instanceIdPtr.cast());
    _ffi.avSetAudioReceiveCallbackNative(
        instanceIdForFfi, onAudioReceiveNative.cast(), instanceIdPtr.cast());
    _ffi.avSetVideoReceiveCallbackNative(
        instanceIdForFfi, onVideoReceiveNative.cast(), instanceIdPtr.cast());
    _ffi.avSetAudioBitrateCallbackNative(
        instanceIdForFfi, onAudioBitrateNative.cast(), instanceIdPtr.cast());
    _ffi.avSetVideoBitrateCallbackNative(
        instanceIdForFfi, onVideoBitrateNative.cast(), instanceIdPtr.cast());

    _logger?.logDebug(
        '[ToxAVService] _setupCallbacks() completed with instanceId=$instanceId');
  }

  // ---------- Static trampoline functions for FFI ----------
  //
  // These execute on the Dart isolate that owns the SendPort and route the
  // callback to the correct service instance using the `userData` pointer
  // (which holds a pointer to the instance ID).
  //
  // CRITICAL FFI SAFETY: The audio/video pointer arguments reference memory
  // owned by c-toxcore that is recycled after the trampoline returns. We
  // copy each buffer into Dart-owned typed-data lists before forwarding.

  static ToxAVService? _lookupService(int instanceId) {
    return instanceId != 0 ? _instanceServices[instanceId] : _globalService;
  }

  static int _readInstanceId(ffi.Pointer<ffi.Void> userData) {
    if (userData.address == 0) return 0;
    return userData.cast<ffi.Int64>().value;
  }

  @pragma('vm:entry-point')
  static void _onCallNativeTrampoline(
    int friendNumber,
    int audioEnabled,
    int videoEnabled,
    ffi.Pointer<ffi.Void> userData,
  ) {
    try {
      final instanceId = _readInstanceId(userData);
      final target = _lookupService(instanceId);
      if (target == null || target._onCall == null) {
        _staticLogger?.logWarning(
            '[ToxAVService] _onCallNativeTrampoline: no service for instanceId=$instanceId');
        return;
      }
      target._logger?.logDebug(
          '[ToxAVService] _onCallNativeTrampoline: friendNumber=$friendNumber audio=$audioEnabled video=$videoEnabled');
      target._onCall!.call(
        friendNumber,
        audioEnabled != 0,
        videoEnabled != 0,
      );
    } catch (e, st) {
      _staticLogger?.logError(
          '[ToxAVService] _onCallNativeTrampoline exception', e, st);
    }
  }

  @pragma('vm:entry-point')
  static void _onCallStateNativeTrampoline(
    int friendNumber,
    int state,
    ffi.Pointer<ffi.Void> userData,
  ) {
    try {
      final instanceId = _readInstanceId(userData);
      final target = _lookupService(instanceId);
      if (target == null || target._onCallState == null) {
        _staticLogger?.logWarning(
            '[ToxAVService] _onCallStateNativeTrampoline: no service for instanceId=$instanceId');
        return;
      }
      target._logger?.logDebug(
          '[ToxAVService] _onCallStateNativeTrampoline: friendNumber=$friendNumber state=$state');
      target._onCallState!.call(friendNumber, state);
    } catch (e, st) {
      _staticLogger?.logError(
          '[ToxAVService] _onCallStateNativeTrampoline exception', e, st);
    }
  }

  @pragma('vm:entry-point')
  static void _onAudioReceiveNativeTrampoline(
    int friendNumber,
    ffi.Pointer<ffi.Int16> pcm,
    int sampleCount,
    int channels,
    int samplingRate,
    ffi.Pointer<ffi.Void> userData,
  ) {
    try {
      final instanceId = _readInstanceId(userData);
      final target = _lookupService(instanceId);
      if (target == null || target._onAudioReceive == null) return;

      final pcmCopy = copyAudioForCallback(pcm, sampleCount, channels);

      target._onAudioReceive!(
        friendNumber,
        pcmCopy,
        sampleCount,
        channels,
        samplingRate,
      );
    } catch (e, st) {
      _staticLogger?.logError(
          '[ToxAVService] _onAudioReceiveNativeTrampoline exception', e, st);
    }
  }

  /// Copies the native PCM buffer into a Dart-owned `Int16List`.
  ///
  /// Exposed for testing the FFI-safety invariant: the returned list must be
  /// fully decoupled from `pcm` (mutating or freeing `pcm` afterwards must
  /// not affect the consumer).
  ///
  /// `sampleCount` is per-channel; total interleaved samples = `sampleCount *
  /// channels` (matching the libtoxav `toxav_audio_receive_frame_cb` contract).
  static Int16List copyAudioForCallback(
      ffi.Pointer<ffi.Int16> pcm, int sampleCount, int channels) {
    final totalSamples = sampleCount * (channels <= 0 ? 1 : channels);
    final pcmCopy = Int16List(totalSamples);
    pcmCopy.setAll(0, pcm.asTypedList(totalSamples));
    return pcmCopy;
  }

  @pragma('vm:entry-point')
  static void _onVideoReceiveNativeTrampoline(
    int friendNumber,
    int width,
    int height,
    ffi.Pointer<ffi.Uint8> y,
    ffi.Pointer<ffi.Uint8> u,
    ffi.Pointer<ffi.Uint8> v,
    ffi.Pointer<ffi.Void> userData,
  ) {
    try {
      final instanceId = _readInstanceId(userData);
      final target = _lookupService(instanceId);
      if (target == null || target._onVideoReceive == null) return;

      if (width <= 0 || height <= 0) return;
      final planes = copyVideoForCallback(width, height, y, u, v);

      target._onVideoReceive!(
        friendNumber,
        width,
        height,
        planes.$1,
        planes.$2,
        planes.$3,
      );
    } catch (e, st) {
      _staticLogger?.logError(
          '[ToxAVService] _onVideoReceiveNativeTrampoline exception', e, st);
    }
  }

  @pragma('vm:entry-point')
  static void _onAudioBitrateNativeTrampoline(
    int friendNumber,
    int audioBitRate,
    ffi.Pointer<ffi.Void> userData,
  ) {
    try {
      final instanceId = _readInstanceId(userData);
      final target = _lookupService(instanceId);
      if (target == null || target._onAudioBitrateChanged == null) {
        _staticLogger?.logWarning(
            '[ToxAVService] _onAudioBitrateNativeTrampoline: no service/handler for instanceId=$instanceId');
        return;
      }
      target._logger?.logDebug(
          '[ToxAVService] _onAudioBitrateNativeTrampoline: friendNumber=$friendNumber audioBitRate=$audioBitRate');
      target._onAudioBitrateChanged!.call(friendNumber, audioBitRate);
    } catch (e, st) {
      _staticLogger?.logError(
          '[ToxAVService] _onAudioBitrateNativeTrampoline exception', e, st);
    }
  }

  @pragma('vm:entry-point')
  static void _onVideoBitrateNativeTrampoline(
    int friendNumber,
    int videoBitRate,
    ffi.Pointer<ffi.Void> userData,
  ) {
    try {
      final instanceId = _readInstanceId(userData);
      final target = _lookupService(instanceId);
      if (target == null || target._onVideoBitrateChanged == null) {
        _staticLogger?.logWarning(
            '[ToxAVService] _onVideoBitrateNativeTrampoline: no service/handler for instanceId=$instanceId');
        return;
      }
      target._logger?.logDebug(
          '[ToxAVService] _onVideoBitrateNativeTrampoline: friendNumber=$friendNumber videoBitRate=$videoBitRate');
      target._onVideoBitrateChanged!.call(friendNumber, videoBitRate);
    } catch (e, st) {
      _staticLogger?.logError(
          '[ToxAVService] _onVideoBitrateNativeTrampoline exception', e, st);
    }
  }

  /// Copies the native I420 planes into Dart-owned `Uint8List`s.
  ///
  /// Returns `(y, u, v)`. See [copyAudioForCallback] for the safety rationale.
  static (Uint8List, Uint8List, Uint8List) copyVideoForCallback(
      int width,
      int height,
      ffi.Pointer<ffi.Uint8> y,
      ffi.Pointer<ffi.Uint8> u,
      ffi.Pointer<ffi.Uint8> v) {
    final ySize = width * height;
    final uvSize = (width ~/ 2) * (height ~/ 2);
    final yCopy = Uint8List(ySize);
    yCopy.setAll(0, y.asTypedList(ySize));
    final uCopy = Uint8List(uvSize);
    uCopy.setAll(0, u.asTypedList(uvSize));
    final vCopy = Uint8List(uvSize);
    vCopy.setAll(0, v.asTypedList(uvSize));
    return (yCopy, uCopy, vCopy);
  }

  /// Set call callback
  void setCallCallback(CallCallback? callback) {
    _onCall = callback;
  }

  /// Set call state callback
  void setCallStateCallback(CallStateCallback? callback) {
    _onCallState = callback;
  }

  /// Set audio receive callback
  void setAudioReceiveCallback(AudioReceiveCallback? callback) {
    _onAudioReceive = callback;
  }

  /// Set video receive callback
  void setVideoReceiveCallback(VideoReceiveCallback? callback) {
    _onVideoReceive = callback;
  }

  /// Set audio-bitrate-changed callback (fires when the peer suggests a new
  /// audio bit rate via toxav_audio_bit_rate_cb).
  void setAudioBitrateChangedCallback(AudioBitrateChangedCallback? callback) {
    _onAudioBitrateChanged = callback;
  }

  /// Set video-bitrate-changed callback (fires when the peer suggests a new
  /// video bit rate via toxav_video_bit_rate_cb).
  void setVideoBitrateChangedCallback(VideoBitrateChangedCallback? callback) {
    _onVideoBitrateChanged = callback;
  }

  /// Start a call
  @override
  Future<bool> startCall(int friendNumber,
      {int audioBitRate = 48, int videoBitRate = 5000}) async {
    _logger?.log(
        '[ToxAVService] startCall: friendNumber=$friendNumber audio=$audioBitRate video=$videoBitRate');
    if (!_initialized) {
      _logger?.logDebug('[ToxAVService] startCall: not initialized, initializing…');
      final initResult = await initialize();
      if (!initResult) {
        _logger?.logWarning('[ToxAVService] startCall: initialization failed');
        return false;
      }
    }

    final result = _ffi.avStartCallNative(
        _ffi.getCurrentInstanceId(), friendNumber, audioBitRate, videoBitRate);
    final success = result == 1;
    if (success) {
      _logger?.log('[ToxAVService] startCall succeeded: friendNumber=$friendNumber');
    } else {
      _logger?.logWarning(
          '[ToxAVService] startCall failed: friendNumber=$friendNumber result=$result');
    }
    return success;
  }

  /// Answer an incoming call
  @override
  Future<bool> answerCall(int friendNumber,
      {int audioBitRate = 48, int videoBitRate = 5000}) async {
    _logger?.log(
        '[ToxAVService] answerCall: friendNumber=$friendNumber audio=$audioBitRate video=$videoBitRate');
    if (!_initialized) {
      _logger?.logDebug('[ToxAVService] answerCall: not initialized, initializing…');
      final initResult = await initialize();
      if (!initResult) {
        _logger?.logWarning('[ToxAVService] answerCall: initialization failed');
        return false;
      }
    }

    final result = _ffi.avAnswerCallNative(
        _ffi.getCurrentInstanceId(), friendNumber, audioBitRate, videoBitRate);
    final success = result == 1;
    if (success) {
      _logger?.log('[ToxAVService] answerCall succeeded: friendNumber=$friendNumber');
    } else {
      _logger?.logWarning(
          '[ToxAVService] answerCall failed: friendNumber=$friendNumber result=$result');
    }
    return success;
  }

  /// End a call
  @override
  Future<bool> endCall(int friendNumber) async {
    _logger?.log('[ToxAVService] endCall: friendNumber=$friendNumber');
    if (!_initialized) {
      _logger?.logWarning('[ToxAVService] endCall: not initialized');
      return false;
    }

    final result =
        _ffi.avEndCallNative(_ffi.getCurrentInstanceId(), friendNumber);
    final success = result == 1;
    if (!success) {
      _logger?.logWarning(
          '[ToxAVService] endCall failed: friendNumber=$friendNumber result=$result');
    }
    return success;
  }

  /// Get user ID (public key hex string) by friend number.
  /// Returns null if the friend number is invalid or lookup fails.
  String? getUserIdByFriendNumber(int friendNumber) {
    final ptr = _ffi.getUserIdByFriendNumberNative(friendNumber);
    if (ptr == ffi.nullptr) return null;
    try {
      return ptr.toDartString();
    } catch (e, st) {
      _logger?.logError(
          '[ToxAVService] getUserIdByFriendNumber error', e, st);
      return null;
    }
  }

  /// Mute/unmute audio
  @override
  Future<bool> muteAudio(int friendNumber, bool mute) async {
    if (!_initialized) return false;

    final result = _ffi.avMuteAudioNative(
        _ffi.getCurrentInstanceId(), friendNumber, mute ? 1 : 0);
    return result == 1;
  }

  /// Hide/show video
  @override
  Future<bool> muteVideo(int friendNumber, bool hide) async {
    if (!_initialized) return false;

    final result = _ffi.avMuteVideoNative(
        _ffi.getCurrentInstanceId(), friendNumber, hide ? 1 : 0);
    return result == 1;
  }

  /// Send audio frame
  Future<bool> sendAudioFrame(int friendNumber, List<int> pcm, int sampleCount,
      int channels, int samplingRate) async {
    if (!_initialized) return false;

    final pcmPtr = pkgffi.malloc<ffi.Int16>(pcm.length);
    try {
      for (int i = 0; i < pcm.length; i++) {
        pcmPtr[i] = pcm[i];
      }

      final result = _ffi.avSendAudioFrameNative(_ffi.getCurrentInstanceId(),
          friendNumber, pcmPtr, sampleCount, channels, samplingRate);
      return result == 1;
    } finally {
      pkgffi.malloc.free(pcmPtr);
    }
  }

  /// Send video frame (YUV420 format)
  Future<bool> sendVideoFrame(int friendNumber, int width, int height,
      List<int> y, List<int> u, List<int> v,
      {int yStride = 0, int uStride = 0, int vStride = 0}) async {
    if (!_initialized) return false;

    final yPtr = pkgffi.malloc<ffi.Uint8>(y.length);
    final uPtr = pkgffi.malloc<ffi.Uint8>(u.length);
    final vPtr = pkgffi.malloc<ffi.Uint8>(v.length);

    try {
      for (int i = 0; i < y.length; i++) {
        yPtr[i] = y[i];
      }
      for (int i = 0; i < u.length; i++) {
        uPtr[i] = u[i];
      }
      for (int i = 0; i < v.length; i++) {
        vPtr[i] = v[i];
      }

      final result = _ffi.avSendVideoFrameNative(
        _ffi.getCurrentInstanceId(),
        friendNumber,
        width,
        height,
        yPtr,
        uPtr,
        vPtr,
        yStride > 0 ? yStride : width,
        uStride > 0 ? uStride : width ~/ 2,
        vStride > 0 ? vStride : width ~/ 2,
      );
      return result == 1;
    } finally {
      pkgffi.malloc.free(yPtr);
      pkgffi.malloc.free(uPtr);
      pkgffi.malloc.free(vPtr);
    }
  }

  /// Set audio bit rate
  Future<bool> setAudioBitRate(int friendNumber, int audioBitRate) async {
    if (!_initialized) return false;

    final result = _ffi.avSetAudioBitRateNative(
        _ffi.getCurrentInstanceId(), friendNumber, audioBitRate);
    return result == 1;
  }

  /// Set video bit rate
  Future<bool> setVideoBitRate(int friendNumber, int videoBitRate) async {
    if (!_initialized) return false;

    final result = _ffi.avSetVideoBitRateNative(
        _ffi.getCurrentInstanceId(), friendNumber, videoBitRate);
    return result == 1;
  }

  /// Get friend number by user ID
  @override
  int getFriendNumberByUserId(String userId) {
    _logger?.logDebug(
        '[ToxAVService] getFriendNumberByUserId: userId.length=${userId.length}');
    final userIdPtr = userId.toNativeUtf8();
    try {
      final result = _ffi.getFriendNumberByUserIdNative(userIdPtr);
      if (result == 0xFFFFFFFF) {
        _logger?.logWarning(
            '[ToxAVService] getFriendNumberByUserId: friend not found');
      }
      return result;
    } finally {
      pkgffi.malloc.free(userIdPtr);
    }
  }

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isAvailable => _ffi.avIsAvailable;

  /// Friend transport connection status: 0 = offline, 1 = TCP, 2 = UDP,
  /// -1 = unknown (native error, or an older library without the symbol).
  /// Cheap enough for a ~1s reconnect watchdog during active calls.
  int getFriendConnectionStatus(int friendNumber) {
    try {
      return _ffi.getFriendConnectionStatusNative(
          _ffi.getCurrentInstanceId(), friendNumber);
    } on ArgumentError {
      return -1;
    }
  }
}
