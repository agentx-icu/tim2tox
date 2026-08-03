[简体中文](./README.zh-CN.md)

# Tim2Tox Dart Package

The Tim2Tox Dart package provides Dart bindings and the SDK Platform implementation for the Tim2Tox framework. Package name: `tim2tox_dart`.

> **Full integration entry points** are at the repo root:
>
> - Project positioning, two integration paths, five integration steps: [`../README.md`](../README.md)
> - In-depth documentation and recommended reading paths: [`../doc/README.md`](../doc/README.md)
> - Build guide: [`../README_BUILD.md`](../README_BUILD.md)
> - **Full API reference**: [`../doc/api/API_REFERENCE_DART.md`](../doc/api/API_REFERENCE_DART.md)

## Layout

```
dart/
├── lib/
│   ├── tim2tox_dart.dart           # Public barrel
│   ├── ffi/
│   │   └── tim2tox_ffi.dart        # Low-level dart:ffi bindings (Tim2ToxFfi)
│   ├── service/
│   │   ├── ffi_chat_service.dart   # Service layer — main app entry point
│   │   ├── call_bridge_service.dart
│   │   ├── toxav_service.dart
│   │   ├── av_codec_service.dart
│   │   ├── call_av_backend.dart
│   │   ├── tuicallkit_adapter.dart
│   │   ├── tuicallkit_integration.dart
│   │   ├── tuicallkit_interceptor.dart
│   │   ├── tuicallkit_patch.dart
│   │   └── tuicallkit_tuicore_integration.dart
│   ├── sdk/
│   │   ├── tim2tox_sdk_platform.dart            # TencentCloudChatSdkPlatform implementation
│   │   ├── tim2tox_sdk_platform_callbacks.dart
│   │   └── tim2tox_sdk_platform_converters.dart
│   ├── interfaces/                  # Injection interfaces the client implements
│   │   ├── preferences_service.dart
│   │   ├── extended_preferences_service.dart
│   │   ├── logger_service.dart
│   │   ├── bootstrap_service.dart
│   │   ├── event_bus.dart
│   │   ├── event_bus_provider.dart
│   │   └── conversation_manager_provider.dart
│   ├── instance/
│   │   └── tim2tox_instance.dart    # Multi-instance context
│   ├── models/
│   │   ├── chat_message.dart
│   │   └── fake_models.dart         # Fake models used to bridge to UIKit
│   └── utils/
│       ├── message_history_persistence.dart
│       ├── binary_replacement_history_hook.dart
│       ├── message_converter.dart
│       ├── conversation_id_utils.dart
│       ├── message_id_generator.dart
│       ├── offline_message_queue_persistence.dart
│       └── tim2tox_failed_message_persistence.dart
├── pubspec.yaml
└── README.md
```

## Usage

### 1. Add the dependency (path example)

```yaml
dependencies:
  tim2tox_dart:
    path: ../tim2tox/dart       # under toxee: third_party/tim2tox/dart
```

### 2. Implement the injection interfaces

**Both `FfiChatService` and `Tim2ToxSdkPlatform` require an `ExtendedPreferencesService`, not just `PreferencesService`.** `PreferencesService` has 7 basic key/value methods; `ExtendedPreferencesService` extends it with ~40 domain methods (groups, friend metadata, Bootstrap, avatars, blacklist, ...).

```dart
import 'package:tim2tox_dart/tim2tox_dart.dart';   // re-exports every interface
import 'package:shared_preferences/shared_preferences.dart';

class MyPreferencesService implements ExtendedPreferencesService {
  final SharedPreferences _prefs;
  MyPreferencesService(this._prefs);

  // ---- Base PreferencesService ----
  @override
  Future<String?> getString(String key) async => _prefs.getString(key);
  @override
  Future<void>    setString(String key, String value) async {
    await _prefs.setString(key, value);
  }
  @override
  Future<bool?>   getBool(String key)  async => _prefs.getBool(key);
  @override
  Future<void>    setBool(String key, bool value) async {
    await _prefs.setBool(key, value);
  }
  @override
  Future<int?>    getInt(String key)   async => _prefs.getInt(key);
  @override
  Future<void>    setInt(String key, int value) async {
    await _prefs.setInt(key, value);
  }
  @override
  Future<void>    remove(String key) async {
    await _prefs.remove(key);
  }

  // ---- ExtendedPreferencesService extension (~40 methods) ----
  // Groups / friend metadata / Bootstrap / avatars / blacklist / ...
  // Full method list: dart/lib/interfaces/extended_preferences_service.dart
  // or doc/api/API_REFERENCE_DART.md
  @override
  Future<Set<String>> getGroups() async {
    final json = _prefs.getStringList('groups') ?? const [];
    return json.toSet();
  }
  @override
  Future<void> setGroups(Set<String> groups) async {
    await _prefs.setStringList('groups', groups.toList());
  }
  // ... etc.
}
```

> Recommended: copy the abstract method signatures from `dart/lib/interfaces/extended_preferences_service.dart` as the initial skeleton and wire each one to your storage backend.

### 3. Initialize `FfiChatService`

```dart
import 'package:tim2tox_dart/tim2tox_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

final prefsService     = MyPreferencesService(await SharedPreferences.getInstance());
final loggerService    = MyLoggerService();
final bootstrapService = MyBootstrapService();          // optional

final ffiService = FfiChatService(
  preferencesService: prefsService,
  loggerService:      loggerService,
  bootstrapService:   bootstrapService,
  // Optional injections: messageHistoryPersistence, offlineMessageQueuePersistence,
  //                      historyDirectory, queueFilePath, fileRecvPath, avatarsPath,
  //                      eventBusProvider, conversationManagerProvider, ...
);

await ffiService.init();
// After login, call ffiService.startPolling() explicitly — without it, no events reach Dart.
```

For the full constructor parameter list, see `dart/lib/service/ffi_chat_service.dart` and [API_REFERENCE_DART.md](../doc/api/API_REFERENCE_DART.md).

### 4. Install the SDK Platform (Platform path)

```dart
import 'package:tim2tox_dart/tim2tox_dart.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';

TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(
  ffiService: ffiService,
);
```

## Notes

- Do not confuse `FfiChatService` and `Tim2ToxSdkPlatform` method names:
  - `FfiChatService` uses lower-level names (`sendText` / `sendTyping` / `sendC2CCustom` / `sendGroupText` / ...).
  - `Tim2ToxSdkPlatform` uses V2TIM-style names (`sendMessage` / `setTyping` / ...).
- **`startPolling()` is explicit**: you must call it once after `login()` finishes; otherwise no events flow back from native into Dart.
- History is persisted on the Dart side (`MessageHistoryPersistence`); C++ does not store history. In hybrid mode, don't let both paths write history at once (see `BinaryReplacementHistoryHook`).
- This README only covers the package layout and the minimal skeleton. For the full integration story and decisions, defer to the root README and the doc index.
