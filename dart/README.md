# Tim2Tox Dart Package
> 语言 / Language: [中文](README.md) | [English](README.en.md)

Tim2Tox Dart 包提供 Tim2Tox 框架的 Dart 绑定与 SDK Platform 实现，包名 `tim2tox_dart`。

> **完整集成入口**请从仓库根目录开始：
>
> - 项目定位、两种接入路径、集成 5 步摘要：[`../README.md`](../README.md)
> - 深度文档与推荐阅读路径：[`../doc/README.md`](../doc/README.md)
> - 构建说明：[`../README_BUILD.md`](../README_BUILD.md)
> - **完整 API 参考**：[`../doc/api/API_REFERENCE_DART.md`](../doc/api/API_REFERENCE_DART.md)

## 目录结构

```
dart/
├── lib/
│   ├── tim2tox_dart.dart           # 主导出（barrel）
│   ├── ffi/
│   │   └── tim2tox_ffi.dart        # 底层 dart:ffi 绑定（Tim2ToxFfi）
│   ├── service/
│   │   ├── ffi_chat_service.dart   # 服务层，应用主要入口
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
│   │   ├── tim2tox_sdk_platform.dart            # TencentCloudChatSdkPlatform 实现
│   │   ├── tim2tox_sdk_platform_callbacks.dart
│   │   └── tim2tox_sdk_platform_converters.dart
│   ├── interfaces/                  # 客户端需实现的注入接口
│   │   ├── preferences_service.dart
│   │   ├── extended_preferences_service.dart
│   │   ├── logger_service.dart
│   │   ├── bootstrap_service.dart
│   │   ├── event_bus.dart
│   │   ├── event_bus_provider.dart
│   │   └── conversation_manager_provider.dart
│   ├── instance/
│   │   └── tim2tox_instance.dart    # 多实例上下文
│   ├── models/
│   │   ├── chat_message.dart
│   │   └── fake_models.dart         # 与 UIKit 桥接用的 fake model
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

## 使用方式

### 1. 添加依赖（path 示例）

```yaml
dependencies:
  tim2tox_dart:
    path: ../tim2tox/dart       # 或在 toxee 中：third_party/tim2tox/dart
```

### 2. 实现注入接口

**`FfiChatService` 与 `Tim2ToxSdkPlatform` 都要求 `ExtendedPreferencesService`，不只是 `PreferencesService`。** 后者只有 7 个基础键值方法；前者继承自它并额外要求约 40 个领域方法（群、好友资料、Bootstrap、头像、黑名单等）。

```dart
import 'package:tim2tox_dart/tim2tox_dart.dart';   // 重导出全部接口
import 'package:shared_preferences/shared_preferences.dart';

class MyPreferencesService implements ExtendedPreferencesService {
  final SharedPreferences _prefs;
  MyPreferencesService(this._prefs);

  // ---- 基础 PreferencesService ----
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

  // ---- ExtendedPreferencesService 扩展（约 40 个方法） ----
  // 群 / 好友资料 / Bootstrap / 头像 / 黑名单 / ...
  // 完整方法见 dart/lib/interfaces/extended_preferences_service.dart
  // 或 doc/api/API_REFERENCE_DART.md
  // 这里仅展示一个例子：
  @override
  Future<Set<String>> getGroups() async {
    final json = _prefs.getStringList('groups') ?? const [];
    return json.toSet();
  }
  @override
  Future<void> setGroups(Set<String> groups) async {
    await _prefs.setStringList('groups', groups.toList());
  }
  // ... 其它 method 同理
}
```

> 建议从 `dart/lib/interfaces/extended_preferences_service.dart` 拷贝抽象方法签名作为初始骨架，然后按需 wire 到你的存储后端。

### 3. 初始化 FfiChatService

```dart
import 'package:tim2tox_dart/tim2tox_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

final prefsService     = MyPreferencesService(await SharedPreferences.getInstance());
final loggerService    = MyLoggerService();
final bootstrapService = MyBootstrapService();          // 可选

final ffiService = FfiChatService(
  preferencesService: prefsService,
  loggerService:      loggerService,
  bootstrapService:   bootstrapService,
  // 可选注入：messageHistoryPersistence、offlineMessageQueuePersistence、
  //          historyDirectory、queueFilePath、fileRecvPath、avatarsPath、
  //          eventBusProvider、conversationManagerProvider、...
);

await ffiService.init();
// 登录后再 ffiService.startPolling()；不显式启动轮询的话事件不会到达 Dart。
```

完整构造参数清单见 `dart/lib/service/ffi_chat_service.dart` 与 [API_REFERENCE_DART.md](../doc/api/API_REFERENCE_DART.md)。

### 4. 设置 SDK Platform（如走 Platform 路径）

```dart
import 'package:tim2tox_dart/tim2tox_dart.dart';
import 'package:tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_platform_interface.dart';

TencentCloudChatSdkPlatform.instance = Tim2ToxSdkPlatform(
  ffiService: ffiService,
);
```

## 注意事项

- 不要混淆 `FfiChatService` 与 `Tim2ToxSdkPlatform` 的方法名：
  - `FfiChatService` 用 lower-level 名（`sendText` / `sendTyping` / `sendC2CCustom` / `sendGroupText` 等）。
  - `Tim2ToxSdkPlatform` 走 V2TIM 风格名（`sendMessage` / `setTyping` / ...）。
- **`startPolling()` 是显式步骤**：`login()` 完成后必须调用一次，否则不会有事件从 native 投递到 Dart。
- 历史在 Dart 侧持久化（`MessageHistoryPersistence`），C++ 不存历史；混合模式下别让两条路径同时写历史（见 `BinaryReplacementHistoryHook`）。
- 本 README 仅覆盖 Dart 包的目录结构与最小骨架；详细接入流程与决策请以根 README 与 doc 索引为准。
