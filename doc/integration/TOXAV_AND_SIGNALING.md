# Tim2Tox ToxAV 与 Signaling
> 语言 / Language: [中文](TOXAV_AND_SIGNALING.md) | [English](TOXAV_AND_SIGNALING.en.md)


本文档说明 tim2tox 当前的通话链路，重点覆盖 `ToxAVService`、`CallBridgeService`、`TUICallKitAdapter` 以及多实例回调路由。

## 1. 目标

tim2tox 当前同时支持两类通话入口：

- **UIKit signaling 通话**：通过 `Tim2ToxSdkPlatform` 暴露的 signaling API 发起 / 接受邀请
- **原生 ToxAV 通话**：直接处理来自 ToxAV 的来电和状态回调，用于 qTox 等互操作场景

这两条路径最终都要落到同一套 ToxAV 实例和媒体回调上。

## 2. 核心组件

### 2.1 `ToxAVService`

位置：`tim2tox/dart/lib/service/toxav_service.dart`

职责：

- 调用 `tim2tox_ffi_av_*` FFI 接口
- 按 `instance_id` 维护 Dart 侧 `ToxAVService` 实例映射
- 注册 call / state / audio / video 四类 native callback
- 对外提供 `startCall()`、`answerCall()`、`endCall()` 等高层方法

### 2.2 `CallBridgeService`

位置：`tim2tox/dart/lib/service/call_bridge_service.dart`

职责：

- 监听 `V2TimSignalingListener`
- 把 signaling invite / cancel / accept / reject / timeout 映射为通话状态机
- 在 accept / reject / timeout 等节点驱动 `ToxAVService`

### 2.3 `TUICallKitAdapter`

位置：`tim2tox/dart/lib/service/tuicallkit_adapter.dart`

职责：

- 作为 TUICore 中 `TUICallingService` 的适配层
- 把 UIKit 的呼叫请求翻译成 signaling invite
- 若能解析出 `friendNumber`，同步触发 `ToxAVService.startCall()`

### 2.4 TUICore 注册

位置：`tim2tox/dart/lib/service/tuicallkit_tuicore_integration.dart`

职责：

- 通过 `registerToxAVWithTUICore(adapter)` 把 `TUICallKitAdapter` 暴露给 TUICore
- 这是 UIKit 通话按钮与 tim2tox 通话栈的唯一注册点

## 3. 调用链路

### 3.1 发起通话（UIKit）

1. UIKit 调用 TUICore 的 `TUICallingService.call`
2. `ToxAVCallService.onCall()` 把请求转交给 `TUICallKitAdapter.handleCall()`
3. `TUICallKitAdapter` 调用 `Tim2ToxSdkPlatform.invite()`
4. 若 invite 成功，则向 UI 抛出 `onOutgoingCallInitiated`
5. 若找到好友 `friendNumber`，继续调用 `ToxAVService.startCall()`

### 3.2 接收 signaling 邀请

1. `Tim2ToxSdkPlatform` 收到 signaling listener 回调
2. `CallBridgeService` 构造 `CallInfo`
3. 上层 UI 决定 accept / reject
4. `CallBridgeService.acceptInvitation()` 先调用 signaling accept，再调用 `ToxAVService.answerCall()`

### 3.3 接收原生 ToxAV 来电

1. C++/FFI 回调进入 `ToxAVService` trampoline
2. 按 `instance_id` 找到目标 `ToxAVService`
3. 上层将其映射为 native call，通常使用 `native_av_<friendNumber>` 形式的 inviteID

## 4. 多实例路由

当前 ToxAV FFI 接口全部显式接收 `instance_id`：

- `tim2tox_ffi_av_initialize(int64_t instance_id)`
- `tim2tox_ffi_av_start_call(int64_t instance_id, ...)`
- `tim2tox_ffi_av_set_*_callback(int64_t instance_id, ...)`

设计原因：

- 自动化测试中存在多个 Tox 实例同时运行
- Dart 侧必须确保 callback 回到正确的 `ToxAVService`
- 因此 `ToxAVService` 构造时会读取 `getCurrentInstanceId()`，并维护 `_instanceServices[instanceId]`

native callback 到 Dart 的最后一跳由 trampoline 完成；它从 `userData` 读取 `instance_id`，再投递到对应服务实例。

## 5. 与客户端的关系

客户端需在设置 `Tim2ToxSdkPlatform` 之后，创建并初始化通话相关组件（如 CallServiceManager），并串起 ToxAVService、CallBridgeService、TUICallKit 适配等。若未先设置 Platform，signaling 路径将不完整。具体接入方式与 UI 集成见各客户端项目文档。

## 6. 当前限制

- `TUICallKitAdapter` 当前只支持 1 对 1 呼叫，群组通话尚未完成
- signaling invite 成功但查不到 `friendNumber` 时，会退化为 signaling-only 状态
- 原生 ToxAV 路径与 signaling 路径共存，因此上层 UI 必须能处理两种 inviteID 形态

## 7. 相关文档

- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md)
- [API 参考](../api/API_REFERENCE.md)
- [MULTI_INSTANCE_SUPPORT.md](../development/MULTI_INSTANCE_SUPPORT.md)
- 通话与扩展能力的客户端侧实现见各客户端项目文档（当 Tim2Tox 作为 submodule 使用时，常见于上层仓库的 doc）。
