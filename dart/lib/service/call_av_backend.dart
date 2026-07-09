abstract class CallAvBackend {
  /// Whether a real AV backend is compiled into the loaded native library.
  /// False means every other method here is a no-op stub (BUILD_TOXAV off)
  /// and the UI must not offer calling.
  bool get isAvailable;

  bool get isInitialized;

  Future<bool> initialize();

  int getFriendNumberByUserId(String userId);

  Future<bool> startCall(
    int friendNumber, {
    int audioBitRate,
    int videoBitRate,
  });

  Future<bool> answerCall(
    int friendNumber, {
    int audioBitRate,
    int videoBitRate,
  });

  Future<bool> endCall(int friendNumber);

  Future<bool> muteAudio(int friendNumber, bool mute);

  Future<bool> muteVideo(int friendNumber, bool hide);
}
