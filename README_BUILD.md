# 构建说明

> 语言 / Language: [中文](README_BUILD.md) | [English](README_BUILD.en.md)

## 快速开始

### 构建 FFI 库（智能构建，**首选**）

```bash
./build_ffi.sh
```

这个脚本会：
- ✅ 仅在需要时构建（库不存在或源文件更新）
- ✅ 自动配置 CMake（如果需要）
- ✅ 启用 ToxAV、DHT_BOOTSTRAP、BOOTSTRAP_DAEMON（auto_tests 使用本地 Bootstrap 时需要）
- ✅ 验证 `Dart_PostCObject_DL` 符号已导出

产物：`build/ffi/libtim2tox_ffi.dylib`（macOS） / `build/ffi/libtim2tox_ffi.so`（Linux）。

### 运行测试（自动构建）

```bash
cd auto_tests
./run_tests.sh                 # 简单运行（含计时输出）
./run_tests_ordered.sh         # 推荐：按 Phase 1-14 顺序运行，单测 180s 超时
```

测试脚本会自动 `./build_ffi.sh`，仅在必要时构建。详见 [auto_tests/README.md](auto_tests/README.md)。

## 构建选项详解

### 1. 增量 FFI 构建（推荐）

```bash
./build_ffi.sh
```

**特点**：
- 仅在源/CMake 文件比库新时构建。
- 配置时启用 `BUILD_TOXAV=ON`、`MUST_BUILD_TOXAV=ON`、`DHT_BOOTSTRAP=ON`、`BOOTSTRAP_DAEMON=ON`、`BUILD_FFI=ON`、`ENABLE_STATIC=ON`、`ENABLE_SHARED=OFF`、`USE_IPV6=ON`、`CMAKE_BUILD_TYPE=Release`。
- 只构建 `tim2tox_ffi` target（不构建 `libtim2tox.a` 及示例）。
- macOS 下自动尝试找 Homebrew 安装的 `opus`、`libvpx`、`libconfig` 等依赖。

### 2. 基础静态库构建（`build.sh`）

```bash
bash build.sh
```

**特点**：
- 全量配置 + `make -j$(sysctl -n hw.ncpu)`，但**关闭**了 ToxAV / DHT_bootstrap / Bootstrap daemon（参见脚本头部的 `-DBUILD_TOXAV=OFF -DDHT_BOOTSTRAP=OFF -DBOOTSTRAP_DAEMON=OFF`）。
- 产出 `build/source/libtim2tox.a` 等静态库；不专门 build `tim2tox_ffi`（虽然 `BUILD_FFI` 默认 ON）。
- 用途：跑 C++ 单测、构建 example、或在不需要通话能力的场景出静态产物。

> **重要差异**：`build.sh` ≠ "完整构建"。如果你需要通话能力或本地 Bootstrap（auto_tests），请使用 `./build_ffi.sh`。

### 3. 强制重建

```bash
rm -rf build
./build_ffi.sh
```

或仅清掉库文件：

```bash
rm -f build/ffi/libtim2tox_ffi.dylib build/ffi/libtim2tox_ffi.so
./build_ffi.sh
```

### 4. 测试相关脚本

| 脚本 | 用途 |
|------|------|
| `auto_tests/run_tests.sh [pattern]` | 简单运行，可按名字过滤；自动构建。 |
| `auto_tests/run_tests_ordered.sh [PHASE...]` | 按 Phase 1-14 顺序运行；单测 180s 超时；推荐入口。 |
| `auto_tests/run_all_tests.sh` | `run_tests_ordered.sh` 的兼容封装。 |
| `auto_tests/run_tests_with_lib.sh` | 显式注入 `DYLD_LIBRARY_PATH`，用于在非默认路径下找到 native lib（如手动构建到自定义目录）。 |
| `auto_tests/run_group_tests.sh` | 群相关 phase 的快捷别名。 |
| `auto_tests/run_conversation_test_with_lldb.sh` / `run_pin_test_with_lldb.sh` | 在 lldb 下跑单个 scenario，便于抓 native 栈。 |

## 构建检查逻辑

`build_ffi.sh` 跳过/触发构建的条件：

1. **库文件不存在** → 构建
2. **任意 FFI 源（`ffi/*.cpp/*.h/*.hpp`）比库新** → 重建
3. **`ffi/CMakeLists.txt` 比库新** → 重建
4. **`CMakeCache.txt` 不存在或缺少必要选项** → 重新 configure
5. 其他 → 跳过构建

## 验证构建

```bash
# 检查库文件
ls -la build/ffi/libtim2tox_ffi.dylib   # macOS
ls -la build/ffi/libtim2tox_ffi.so      # Linux

# 验证 Dart_PostCObject_DL 已导出（build_ffi.sh 自带）
nm -g build/ffi/libtim2tox_ffi.dylib | grep Dart_PostCObject_DL
```

## 常见问题

### Q: 如何强制重建？
```bash
rm -rf build
./build_ffi.sh
```

### Q: 构建失败怎么办？
1. 删除整个 `build/` 重新构建。
2. 看终端输出找到第一处 error（CMake 输出通常很长，向上滚到第一处 `error:`）。
3. macOS 上若提示找不到 `opus` / `libvpx`：`brew install opus libvpx libconfig libsodium`。
4. Linux 上若提示找不到 sodium：`sudo apt install libsodium-dev`（或对应发行版的包）。

### Q: 如何只构建 FFI 库？
就是 `./build_ffi.sh`。

### Q: 在哪里看构建日志？
构建日志直接打到终端 stdout/stderr。脚本默认不写 `build.log` —— 如果你需要落盘，请自己 `./build_ffi.sh 2>&1 | tee build.log`。

## 性能参考

- **首次构建**：5-15 分钟（依赖工具链与机器性能）
- **增量构建**：1-5 分钟
- **跳过构建**：< 1 秒（无更改）

## 相关文件

- `build_ffi.sh` — 增量 FFI 构建脚本（首选）
- `build.sh` — 基础静态库构建脚本（不含 ToxAV / DHT_bootstrap）
- `CMakeLists.txt` — 顶层 CMake 配置
- `ffi/CMakeLists.txt` — FFI 子项目
- `auto_tests/run_tests.sh` / `run_tests_ordered.sh` / ... — 测试脚本
