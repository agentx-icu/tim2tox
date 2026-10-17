# 会合群（Rendezvous groups）— 仅作传输的 NGC 单元

会合群让素不相识的客户端不依赖目录或服务器、只通过 Tox DHT 互相找到。每个
客户端从共同知识（toxee：一个 geohash 地理单元）推导出同一个 32 字节种子，
种子确定性地派生出 NGC 密钥对，于是得到确定的 Chat ID，`tox_group_join`
就能通过普通的 DHT 公告查到它。30 秒内没找到任何人的一方用同一密钥对创建
该群（`tox_group_new_with_seed`，这是 `agentx-icu/c-toxcore` fork 分支
`agentx/group-new-with-seed` 携带的私有 toxcore API）。

Tim2Tox 把这类群当作**纯传输**：

- 永远不是 V2TIM 群——没有 `OnJoinedGroup`、没有成员回调、不出现在
  `GetJoinedGroupList`、不向好友做群身份公告；
- 永远不作为已知群持久化，`RejoinKnownGroups` 不会重连它；
- 它的包永远不进消息历史；客户端拿到的是不透明的负载字节，含义由客户端
  自己定义（toxee：在场记录与加好友意向，见 toxee
  `doc/reference/LOCATION_AND_NEARBY.md`）；
- 群自身说的一切（名字、话题、角色、管理事件、密码、隐私状态）一律忽略：
  群主私钥人人可推导，人人都是群主，所以这种群没有管理边界。

## 组成

| 位置 | 内容 |
|---|---|
| `source/Tim2ToxGroupPacket.{h,cpp}` | NGC 自定义包的封帧，聊天类（1–3）与会合类（4）共用 |
| `source/RendezvousGroups.{h,cpp}` + `RendezvousGroupsCodec.cpp` + `RendezvousGroupsEvents.cpp` | 簿记 + 规划器：单元、状态、定时器、对等方表、预算、恢复规则、事件行。**不调用任何 Tox API**；由 `test/RendezvousGroupsTest.cpp` 单测 |
| `source/V2TIMManagerImpl_Rendezvous.cpp` | 驱动：按会话规则执行规划器给出的动作，记录 toxcore 回调，发出事件 |
| `V2TIMManagerImpl.{h,cpp}` | 隔离守卫（每个群回调 / 处理函数首先分流已拥有的群）、`InitSDK` 里的恢复扫描、`UnInitSDK` 里最先执行的 `RendezvousShutdown()`、事件循环里的 `RendezvousTick()` |
| `ffi/tim2tox_ffi.{h,cpp}` | `tim2tox_ffi_rendezvous_*`、`tim2tox_ffi_dht_announce_capable_count`，以及在 `InitSDK` **之前**安装的、带实例号的事件 sink |
| `dart/lib/service/rendezvous_transport.dart` | `RendezvousTransport`：调用封装与解析后的 `Stream<RendezvousEvent>`；`FfiChatService.rendezvous` 在轮询循环里先于任何消息分支喂给它 |

## 单元生命周期（规划器）

```
RequestJoin ──► kJoining ──(self_join 或 peer_join)──► kJoined
                  │ 30 s 两者皆无：离开 + 用同一种子创建 ──► kJoined（founded）
kJoined ──(曾有对等方，90 s 内一个不剩)──► 离开 "stale" ──► kBackoff（15 s）──► kJoining
join_fail / 被踢（管理事件目标是自己）──► 离开 ──► kBackoff
10 分钟内重试超过 3 次 ──► kUnavailable（10 分钟）──► kJoining
RequestLeave / RequestLeaveAll ──► 离开 "left" ──► 遗忘
```

toxcore 回调**只记录**状态并排队下一次 `Tick()`；所有成员关系变更（加入、
创建、离开）都在事件线程的两次迭代之间通过 `PostToEventThread` 执行，绝不
在 toxcore 回调内部执行。

### 会话规则（驱动为何长这样）

- **准入**：`accepting_` 由 `InitSDK` 在 savedata 恢复扫描之后打开，由
  `UnInitSDK` 第一步关闭。
- **代数 + 纪元**：每个被准入的操作捕获注册表代数和会话纪元，固定会话
  （`AcquireToxSession`），在 Tox 调用**之前**复核 pin 的纪元与 `Expired()`，
  在调用**之后**复核代数；活过了自己会话的 join/found 会离开它刚创建的
  群，并且什么都不记录。
- **关闭**：`RendezvousShutdown()` 递增代数，有界等待在途操作，在事件线程上
  离开所有单元（`RunOnEventThread<bool>`，失败则内联兜底），这一切都在 `running_`
  清零和最终保存之前完成。注册表**不**在此清空：事件线程在 `UnInitSDK` 停掉它之前
  可能再迭代一次，而 toxcore 会先投递已标记群的待处理数据包再删除它，所以退役中的
  条目继续分流回调，直到 `ResetGroupSessionState()`（在 `StopBackgroundTasks` 之后）清空。
- **恢复**：崩溃遗留在 savedata 里的单元在恢复扫描中按"名字前缀 **且**
  合法标签 **且** `chat_id == derive(SHA-256(seed_prefix + label))`"识别，
  立即离开、永不登记。`HandleGroupSelfJoin` 做同样检查
  （`RendezvousSelfJoinOfZombie`，离开动作推迟到事件线程）。
- **邀请**：前 32 字节（chat_id）属于某个单元、或名字推导得到该 chat_id
  的邀请，在自动接受之前丢弃。
- **孤儿与僵尸**：注册表在自己的锁内、与记录动作原子地比较捕获的代数
  （`OnJoinIssued` / `OnFoundIssued`）；被拒绝的 join/found 是孤儿，由驱动离开。
  每次 `tox_group_leave` 的结果都会检查（`LeaveGroup()`）：toxcore 即使
  `FAIL_SEND` 也会删除该群，只有未知错误才会保留它，此时群**仍归我们拥有**——
  要么作为重新规划的单元离开（`OnLeaveFailed`，`kLeaveRetryMs` 后重试），
  要么作为僵尸（群号 + chat id）。僵尸在 `Tick()` 里离开，关闭时再离开一次，
  每次都发出对应的 `rendezvous_left`；关闭时仍失败的留给下次恢复扫描。
- **退役中（retiring）**：`tox_group_leave` 只是给群打上标记，toxcore 在下一次
  迭代时才删除它；期间对同一 chat id 的 join 会重新加入那个被标记的群。因此已离开
  的单元仍以 *retiring* 状态归我们拥有（回调仍被分流，不再为它规划任何动作），直到
  某次 tick 观察到该群号已消失或已属于别的 chat id，才应用离开的后果（遗忘、退避、
  refound 的 found、或客户端在此期间要求的重新加入）。每个动作还带着规划时的代数和
  单元的 *attempt* 序号，结果只对完全相同的 attempt 记录——Tox 调用在途期间对同一
  单元的离开 + 重新加入、或 LeaveAll，都会让迟到的结果成为孤儿，由驱动离开。
  被离开的孤儿（以及僵尸、恢复扫描离开的群）成为*退役中的孤儿*：消失前仍归我们拥有，
  期间不规划其 chat id 的任何 join/found。只有群号仍持有我们的 chat id 时才发出离开；
  成功的离开无论代数期间如何变化都会被记录（绝不对 toxcore 可能已复用的群号再离开一次）。
  仅剩的一个窗口——toxcore 在 `tox_iterate` 里删除了群，而下一次 tick 之前普通群的创建
  复用了该群号——由 self-join 路径核对 chat id 后释放退役条目，而不是分流该回调。
- **失败的尝试会上报**：同步失败的 `tox_group_join` / `tox_group_new_with_seed`
  发出 `rendezvous_left:<chat_id>:failed`（注册表退避并重试），因此 `join`
  返回 `1` 的客户端总能得知结果。
- **关闭时的事件行到不了 Dart**：`tim2tox_ffi_uninit` 在 `UnInitSDK` 之后立即
  清空实例队列，关闭阶段离开单元产生的 `rendezvous_left` 永远不会被轮询到。
  Dart 侧 `RendezvousTransport` 按实例跟踪已加入的单元，在 `dispose()`
  （`FfiChatService.dispose()` 的第一步；不等待暂停中的订阅者，并为同一服务的
  重新初始化换上新的流）里把每个单元上报为 `left`，消费者的会话视图无论如何
  都会被关闭。

## 线上格式与事件

类型 4 帧：`0xB7 'T' '2' 'T' 0x01 0x04 <payload>`；整帧最多 **1200 字节**
（负载 ≤ 1194）。类型 4 只在已拥有的群里被接受；已拥有的群里的其他类型、
以及其他群里的类型 4，一律丢弃。

原生侧按发送方预算，在任何东西入队之前执行：每 (群, 对等方公钥) 每 10 s
最多 6 个包、6 KiB；每群每 10 s 最多 60 个对等方事件，超出后合并为一条
`rendezvous_peers_changed`。丢弃有计数（`tim2tox_ffi_rendezvous_drop_count`）。

轮询行（带实例号；`rendezvous_packet:` 与聊天事件同为可淘汰类）：

```
rendezvous_joined:<chat_id_hex>:<founded 0|1>
rendezvous_left:<chat_id_hex>:<kicked|failed|stale|left|full>
rendezvous_peer:<chat_id_hex>:<peer_pk_hex>:<join|exit>
rendezvous_peers_changed:<chat_id_hex>:<count>
rendezvous_full:<chat_id_hex>
rendezvous_packet:<chat_id_hex>:<peer_pk_hex>:<b|p>:<hex payload>
```

## 约定

默认值是 toxee 的协议字面量，可在 init 之前用
`tim2tox_ffi_rendezvous_set_convention` 修改：

| | 默认 | 用途 |
|---|---|---|
| 群名 | `toxee-nearby/v1/` + 标签 | 创建者设置的名字；恢复扫描解析的对象 |
| 种子 | `SHA-256("toxee/nearby/v1|" + 标签)` | 客户端传给 `join` 的值；恢复扫描重新推导的值 |

标签为 1–12 个 geohash base32 字母表字符。

## 测试

- `test/Tim2ToxGroupPacketTest.cpp`、`test/RendezvousGroupsTest.cpp`、
  `test/RendezvousIsolationSourceRegressionTest.cpp`（gtest，
  `-DTIM2TOX_BUILD_TESTS=ON`）。
- `dart/test/rendezvous_transport_event_test.dart`（事件行解析）。
- `auto_tests/test/scenarios/scenario_rendezvous_group_test.dart`（第 4 阶段）：
  创建 → 加入 → 广播 → 私包 → 隔离 → 预算 → 离开，单进程双实例。
- toxcore fork：`auto_tests/group_seeded_test.c`（种子确定性）。
