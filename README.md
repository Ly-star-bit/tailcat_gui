# Tailcat GUI

Android / macOS / Windows 图形界面，封装 [tailcat](https://github.com/tailscale/tailcat)
（Tailscale 开源的免账号、免 root 的 WireGuard + NAT 穿透工具）。

一端生成 `tc…` 令牌，另一端输入令牌即可：传文件、共享端口、SOCKS5 代理、SSH。
与官方 `tailcat` 命令行完全互通（同一版本的 wire format）。

## 架构

```
Flutter UI (Dart)  ──dart:ffi──▶  libtailcat_core (Go, c-shared)  ──▶  github.com/tailscale/tailcat
      app/                         core/bridge  +  core/engine
```

- `core/engine`：会话模型 + JSON 命令/事件 API。直接调用 tailcat 库，不启动子进程。
  - `start_server`（= `tailcat serve ports|all|exit-node|files|no-auth-ssh`）
  - `start_forward`（本地端口 → 对方端口，CLI 没有的功能）
  - `start_socks`（= `tailcat socks --listen`）
  - `send_files` / `list_remote` / `download`（SFTP，与 `tailcat cp/ls/recv` 互通）
  - `start_ssh_forward`（桌面：本地端口转发到对方 22，再交给系统 `ssh`）
  - `probe`（连接令牌后自动探测：先读服务端在 1 号端口发布的「清单」；对纯命令行服务端则探测 22 端口是否有 SFTP / shell）
  - `start_server` 一个令牌可同时包含文件、端口、出口节点、SSH；`share_paths` 直接分享选中的文件
  - `ping` / `parse_token` / `stop` / `list_sessions` / `get_caps`
- `core/engine/fileshare`：自研「仅 SFTP 子系统」的免认证 SSH 服务端 + 客户端。
  tailcat 内置的 SSH/SFTP 服务端在 Android 上不可用（build tag），这个包三端一致并带进度回调。
- `core/bridge`：6 个 C 函数（`tc_init/tc_call/tc_poll/tc_free/tc_version/tc_shutdown`），见 `bridge.h`。
- `app/packages/tailcat_core_ffi`：Flutter FFI 插件，打包预编译的 `.so/.dylib/.dll`。
- `app/`：Flutter 应用（Riverpod）。只有两个入口：**分享**（勾选文件/文件夹/端口/出口节点/SSH，生成一个令牌）
  和 **连接**（粘贴或扫描令牌，自动显示对方提供了什么并给出操作）。剪贴板里有令牌会直接提示连接；记住最近连接过的设备。

## 构建（全部 headless，不会启动 GUI）

```sh
# Go 核心
make core-test          # go vet + 单元测试（不联网）
make core-e2e           # 走 Tailscale 公共 DERP 的端到端测试（TAILCAT_E2E=1）
make core-cross         # android / windows / linux 编译检查

# 原生库
make macos              # build/out/macos/libtailcat_core.dylib（arm64+x86_64）
make android            # build/out/android/{arm64-v8a,x86_64}/libtailcat_core.so（需 Android NDK）
make windows            # build/out/windows/x64/tailcat_core.dll（需 brew install mingw-w64）
make sync               # 复制进 app/packages/tailcat_core_ffi

# Flutter
make app-analyze
make app-test
make apk                # flutter build apk --debug（仅构建）
```

macOS 应用打包需要完整 Xcode（`flutter build macos`）；Windows 应用需要在 Windows 上或 CI 构建
（`.github/workflows/`）。Go 库本身在 macOS 上用 Command Line Tools + mingw 即可交叉编译。

## 与命令行互通

| GUI 操作 | 等价 CLI |
|---|---|
| 分享 → 发送文件（生成令牌） | 无直接等价；CLI 用 `tailcat cp tc…:file .` 可取回 |
| 分享 → 接收文件 | `tailcat recv ~/inbox`（CLI 用 `tailcat cp file tc…:` 发送） |
| 分享 → 共享文件夹 | `tailcat serve --files=DIR:ro files` |
| 分享 → 端口 / 所有端口 / 出口节点 / SSH | `tailcat serve 8080` / `all` / `exit-node` / `no-auth-ssh` |
| 连接 → 全部接收 / 浏览 | `tailcat cp tc…:. .` / `tailcat ls -l tc…` |
| 连接 → 映射端口到本机 | 无 CLI 等价（CLI 只有 stdin/stdout 管道） |
| 连接 → SOCKS5 | `tailcat socks --listen 1080 tc…` |
| 连接 → SSH 登录（桌面） | `tailcat ssh tc…` |

连接命令行起的服务端时没有清单，App 会探测 22 端口并允许手动填端口号映射。

## 注意

- tailcat 无 API/wire 稳定承诺：两端应使用相同版本（首页底部显示 core 与 tailcat 版本）。
- Android 上应用需保持前台，v1 未做前台服务。
- 免密 SSH 谁拿到令牌谁就能登录，仅用于临时调试。
- Windows 首次监听端口会弹防火墙提示；`ssh.exe` 使用系统自带 OpenSSH。
