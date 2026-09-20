<h1 align="center">dsh-shortcut</h1>

<p align="center">
  Run <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a> in its own application window on Windows and macOS.
</p>

<div align="center">

[![Windows](https://img.shields.io/badge/Windows-10%2B-0078D4?style=flat-square&logo=windows)](https://www.microsoft.com/windows)
[![macOS](https://img.shields.io/badge/macOS-Intel%20%7C%20Apple%20Silicon-000000?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell)](https://learn.microsoft.com/powershell/)
[![Node](https://img.shields.io/badge/Node-22.19%2B%20%7C%2024%2B-339933?style=flat-square&logo=node.js)](https://nodejs.org/)
[![License](https://img.shields.io/badge/License-MIT-333333?style=flat-square)](LICENSE)

</div>

---

## 概览

`dsh-shortcut` 把 DeepSeek Harness（`dsh`）的 Web UI 变成**独立应用窗口**：没有标签栏、没有地址栏、任务栏有独立图标，看起来就是一个桌面应用。

它做三件事：

1. 首次运行时安装官方 npm 包 `@deepseek-ai/dsh`
2. 启动 `dsh web`（本地服务）
3. 用 Chromium 浏览器的**应用模式**（`--app=`）打开独立窗口，并创建桌面和应用入口

同时，如果电脑上还没有满足要求的 Node.js，脚本会**自动下载适配本机架构的
Node.js 运行时**并校验 SHA256。Windows 优先打开官方安装向导，取消或无法交互时回退为便携安装；
macOS 使用原生文件夹选择框选择便携运行时目录，取消或无法交互时使用应用目录下的 `node`。
便携安装不需要管理员权限，也不改动系统 PATH。

每次启动还会自动和仓库比对启动器与图标，有更新就替换并立即用新版本重启（见「自动同步」）。

原有的 `~/.dsh` 数据（会话、设置、凭据）完全保留；启动器将自己的 dsh npm 包安装到应用目录，不覆盖已有的全局安装。

## 一键安装

### Windows

在 PowerShell 里运行：

```powershell
irm https://raw.githubusercontent.com/dieWehmut/dsh-shortcut/main/install.ps1 | iex
```

安装完成后，桌面和开始菜单会出现 **DeepSeek Harness** 快捷方式，双击即可打开独立窗口。

### macOS

在终端里运行：

```bash
curl -fsSL https://raw.githubusercontent.com/dieWehmut/dsh-shortcut/main/install.sh | bash
```

默认安装到 `~/Library/Application Support/dsh-shortcut`，在桌面和 `~/Applications` 创建
**DeepSeek Harness.command**。双击即可启动；默认使用 Chrome，也支持 Edge、Brave 和其他 Chromium 浏览器。

自定义安装目录、端口或浏览器：

```bash
curl -fsSL https://raw.githubusercontent.com/dieWehmut/dsh-shortcut/main/install.sh -o /tmp/dsh-install.sh
bash /tmp/dsh-install.sh --app-dir "$HOME/Applications/dsh-shortcut" --port 8080 --browser edge

# 只安装启动器、图标和快捷方式；不安装 Node.js/npm 包，也不启动服务
bash /tmp/dsh-install.sh --no-start
```

安装器会先下载全部文件，检查启动器的 Bash 语法和两张 PNG 图标，再替换本地文件。
第一次启动自动带上 `--no-sync`，避免安装后立即重复下载。其余参数见「macOS 使用」。

## 自动同步

每次启动都会把本机的启动器和图标与仓库内容做一次比对，有差异就替换，然后用新版本继续本次启动。所以仓库里发布的修复不需要重新安装就会到达这台机器。

- 比对的是内容（SHA256），不是版本号，只看仓库 `main` 分支
- 更新后的文件立即生效：脚本会用原参数重启一次，这次重启只发生一次
- 从源码目录直接运行时只更新本机安装，不会重启（避免打断开发中的调试）
- 断网、仓库 404 或返回空文件时保持本机副本，启动照常继续
- 仓库里的启动器语法不通过时拒绝安装，本机副本继续可用
- 想跳过这次比对：Windows 加 `-NoSync`，macOS 加 `--no-sync`

## Windows 环境要求

- Windows 10 或更高
- PowerShell 5.1 或更高（系统自带）
- **Node.js 22.19+ 或 24+**，没有也可以：脚本会自动安装（见「自动安装 Node.js」）
- Edge 或 Chrome（用于应用窗口模式；两者都没有时会退回默认浏览器的普通标签页）

启动器和便携运行时只安装到当前用户目录，不需要管理员权限；Node.js 官方安装向导可能要求管理员确认。

## Windows 自动安装 Node.js

启动时会先找可用的 Node.js（22.19+，或 24+）：

1. 已安装且版本满足要求 → 直接使用（包括安装到自定义目录的，按注册表记录定位）
2. 安装了但版本过旧，或完全没有 → 弹出 **Node.js 官方安装向导**，可以自己选择安装位置
   和选项；下载后的安装包与官方 SHA256 校验一致才运行（x64 / arm64 / x86 自动识别，
   nodejs.org 不通时自动改用 npmmirror 镜像）
3. 向导被取消、UAC 被拒绝，或没有可交互桌面（无人值守）时 → 自动回退为原来的免管理员
   便携安装：解压到 `%LOCALAPPDATA%\dsh-shortcut\node\`，不写系统目录、不改系统 PATH

想跳过向导直接静默安装：加 `-SilentNodeInstall`。

## Windows 使用

### 托盘

启动后会常驻一个**通知区域图标**：

- **关闭窗口不会关闭任务**：服务继续在后台跑，再用托盘把窗口叫回来即可
- **左键单击**托盘图标：打开/前置窗口
- **右键**打开菜单：Open Window、Open in Browser、Restart Server、Copy URL、
  Open Log、Open Install Folder、**Exit（停止服务）**
- **只有 Exit 会真正停止服务**；重复双击快捷方式不会叠加第二个图标，会把已有窗口提到前面
- 想不要托盘（回到旧行为）：加 `-NoTray`

### 快捷方式

双击 **DeepSeek Harness**。已经有一个实例在运行时，脚本会复用该实例而不是再起一个。
复用时会用本机记录的启动令牌恢复已认证的地址，不会再落到 401 认证页。

### 命令行

```powershell
# 默认端口 3080，Edge 应用窗口
& "$env:LOCALAPPDATA\dsh-shortcut\dsh-window.ps1"

# 换端口和浏览器
& "$env:LOCALAPPDATA\dsh-shortcut\dsh-window.ps1" -Port 8080 -Browser chrome

# 只启动服务，不开窗口（打印带 token 的地址）
& "$env:LOCALAPPDATA\dsh-shortcut\dsh-window.ps1" -NoWindow

# 打开一个你自己已经启动的实例
& "$env:LOCALAPPDATA\dsh-shortcut\dsh-window.ps1" -Url 'http://127.0.0.1:3080/'
```

### 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-Port` | `3080` | Web UI 端口；该端口已有实例时直接复用 |
| `-AppDir` | `%LOCALAPPDATA%\dsh-shortcut` | 安装目录 |
| `-Url` | 无 | 直接打开指定地址，不启动也不探测服务 |
| `-NoWindow` | 关闭 | 只启动服务并打印地址，不打开窗口 |
| `-Browser` | `edge` | `edge`、`chrome`，或 Chromium 系浏览器的绝对路径 |
| `-Uninstall` | 关闭 | 删除安装目录和快捷方式（保留 `~/.dsh` 数据） |
| `-NoSync` | 关闭 | 跳过与仓库的比对，直接用本机副本启动 |
| `-SilentNodeInstall` | 关闭 | 不弹 Node.js 安装向导，直接静默安装便携运行时（适合无人值守） |
| `-NoTray` | 关闭 | 不常驻托盘图标（关闭窗口后不提供叫回窗口和停止服务的入口） |

> 注意：便携运行时会随 `-Uninstall` 一起删除（它就在安装目录里）；用官方安装向导装的
> Node.js 是系统级安装，卸载脚本不会动它，需要的话请从「应用和功能」里卸载。

### 卸载

```powershell
& "$env:LOCALAPPDATA\dsh-shortcut\dsh-window.ps1" -Uninstall
```

## macOS 使用

### 环境与 Node.js

- Intel 或 Apple Silicon Mac，使用系统自带的 Bash、curl、AppleScript 和图像工具；不要求 Homebrew
- Chrome、Edge 或 Brave 提供独立应用窗口；找不到可用的 Chromium 浏览器时，打开系统默认浏览器的普通标签页
- Node.js 版本要求与 Windows 一致：22.19+ 或 24+；已有符合要求的运行时就直接使用

需要安装 Node.js 时，会弹出 macOS 原生文件夹选择框；所选目录下保存本工具管理的便携运行时。
取消选择、没有桌面会话或传入 `--silent-node-install` 时，使用安装目录下的 `node`。
下载文件按官方发布的 SHA256 清单验证，按本机选择 `arm64` 或 `x64`；主下载源不可用时尝试镜像。
所选路径记在安装目录的 `node-runtime.path`，以后启动可复用，不改系统 PATH。

### 菜单栏图标与快捷方式

启动后，菜单栏显示适配浅色、深色外观和 Retina 屏幕的模板图标。
左键单击可打开或前置窗口；右键打开菜单：Open Window、Open in Browser、Restart Server、Copy URL、
Open Log、Open Install Folder、Exit。关闭浏览器窗口后服务继续运行；**Exit 停止本工具管理的服务并退出菜单栏图标**。

桌面和 `~/Applications` 的 **DeepSeek Harness.command** 会保留安装时选定的端口、浏览器和安装目录。
同一安装重复启动会复用服务和菜单栏图标。用 `--no-tray` 可禁用图标，用 `--no-window` 可只启动服务并打印地址。

### 命令行与参数

```bash
# 启动窗口和菜单栏图标
bash "$HOME/Library/Application Support/dsh-shortcut/dsh-window.sh"

# 使用另一端口和 Edge
bash "$HOME/Library/Application Support/dsh-shortcut/dsh-window.sh" --port 8080 --browser edge

# 无窗口启动，打印认证地址
bash "$HOME/Library/Application Support/dsh-shortcut/dsh-window.sh" --no-window

# 打开已有服务的认证地址
bash "$HOME/Library/Application Support/dsh-shortcut/dsh-window.sh" --url 'http://127.0.0.1:3080/?token=...'

# 没有菜单栏图标时，通过命令停止本工具管理的服务
bash "$HOME/Library/Application Support/dsh-shortcut/dsh-window.sh" --stop
```

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--port N` | `3080` | Web UI 端口；已有可复用实例时使用该实例 |
| `--app-dir DIR` | `~/Library/Application Support/dsh-shortcut` | 安装目录；使用自定义目录时，后续命令也需传入 |
| `--browser NAME\|PATH` | `chrome` | `chrome`、`edge`、`brave`，或 Chromium 浏览器可执行文件的绝对路径 |
| `--url URL` | 无 | 使用指定地址打开已有服务 |
| `--no-window` | 关闭 | 启动服务并打印地址，不打开窗口或常驻菜单栏图标 |
| `--no-tray` | 关闭 | 打开窗口但不常驻菜单栏图标 |
| `--no-sync` | 关闭 | 本次启动跳过从仓库同步启动器和图标 |
| `--silent-node-install` | 关闭 | 需要下载 Node.js 时，不弹文件夹选择框，使用默认便携目录 |
| `--uninstall` | 关闭 | 停止受管理的服务，删除本工具安装和快捷方式，保留 `~/.dsh` |
| `--self-test` | 关闭 | 在 macOS 桌面会话中编译、启动并检查菜单栏小程序，再退出小程序；不安装 Node.js 或启动 dsh 服务 |
| `--help` | 无 | 显示帮助 |

安装器 `install.sh` 支持上述安装目录、端口、浏览器、URL、无窗口、无托盘、静默 Node 安装和卸载参数，
另外提供 **`--no-start`**：仅安装文件和快捷方式，首次双击时才安装运行时和 npm 包。
`--self-test` 和以下操作参数由 `dsh-window.sh` 提供：
`--open-window`、`--open-browser`、`--restart`、`--copy-url`、`--open-log`、`--open-folder`、`--stop`。
它们针对该安装记录的服务操作；自定义安装请一并传入 `--app-dir` 和 `--port`。

### 设置

在窗口中的 **Settings → Models** 设置模型和 API Key，与 Windows 使用相同的 `~/.dsh` 数据。
需要固定启动参数时，用所需的 `--port`、`--browser` 和 `--app-dir` 重新运行安装器；加 `--no-start`
即可只更新文件和快捷方式。`--silent-node-install` 只控制需要安装 Node.js 时的文件夹选择。

### 卸载

```bash
bash "$HOME/Library/Application Support/dsh-shortcut/dsh-window.sh" --uninstall

# 自定义安装目录
bash "$HOME/Applications/dsh-shortcut/dsh-window.sh" --app-dir "$HOME/Applications/dsh-shortcut" --uninstall
```

也可以用下载后的 `install.sh --uninstall` 调用本地启动器；卸载不需要联网。
安装目录内的便携 Node.js 会随应用删除；选在应用目录之外的 Node.js 和已有的系统 Node.js 不会删除。
会话、模型设置和凭据所在的 `~/.dsh` 始终保留。

## 自定义

### 模型与 API Key

打开窗口后在 **Settings → Models** 里填 API Key 并选择模型，设置保存在 `~/.dsh/settings.yaml` 与 `~/.dsh/.credentials.yaml`，下次启动自动生效。

也可以放在环境变量或 `.env` 里（优先级：进程环境变量 > `.credentials.yaml` > 当前目录 `.env` > `~/.dsh/.env`）：

```powershell
[Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', 'sk-...', 'User')
```

### 固定端口和浏览器

Windows 可修改快捷方式的目标参数，例如把 `-Port 8080 -Browser chrome` 追加到参数末尾；
macOS 可用安装器的 `--port`、`--browser` 和 `--no-start` 更新快捷方式。

## 工作原理

`dsh web` 本身只调用系统默认浏览器打开一个标签页。这个脚本改为：

1. 用 `--no-open` 启动服务，从启动日志里读出带一次性 token 的地址
2. 把这个地址交给 Edge/Chrome 的 `--app=<url>` 模式，得到一个没有浏览器外壳的独立窗口，使用独立的浏览器配置目录
3. 窗口用一次性 token 换取签名 cookie（有效期 30 天，绑定主机和端口），之后的请求都靠 cookie 认证

官方 Web 构建自带安装元数据（`/manifest.webmanifest`，`display: fullscreen`），所以你也可以在窗口里通过浏览器菜单把它「安装为应用」，那样会得到由浏览器托管的 PWA 窗口。

## 常见问题

**窗口显示 unauthorized / 401**
脚本复用已有实例时会用本机记录的令牌自动恢复认证地址，正常情况下不会再出现。
如果仍出现，通常是这个服务是别的程序启动的：关掉那个服务进程，重新双击快捷方式即可。

**提示 Node 版本过低 / 自动安装 Node 失败**
脚本要求 22.19+ 或 24+（与 dsh 的 `engines` 范围一致）。Windows 会自动弹出 Node.js 官方安装
向导；向导里取消或拒绝 UAC 时会自动改用便携安装。macOS 会让你选择便携运行时目录，取消时使用默认目录。两个下载源（nodejs.org 与 npmmirror）
都失败时按提示到 [nodejs.org](https://nodejs.org/) 手动安装后重试。

**安装向导弹出来后没反应 / 想装到别的盘**
Windows 的向导就是 Node.js 官方安装程序，按自己的需要选择安装位置即可，装完脚本会自动找到它
（按安装包写入注册表的路径定位，不依赖 PATH）。如果向导没弹出来，可能是这台机器不允许
弹窗（无人值守会话）：脚本会自动转为便携安装。

macOS 使用文件夹选择框，不运行系统安装器；如果取消选择，会继续使用安装目录下的 `node`。

**首次运行很慢**
首次要下载约 500 个 npm 包，通常 1–3 分钟（视网络情况可能更久）。之后启动只需几秒。

**想用系统默认浏览器而不是 Edge/Chrome**
把 `-Browser` 指向别的 Chromium 系浏览器，或者删掉快捷方式参数里的 `-Browser` 并确保系统里没有 Edge/Chrome —— 脚本会退回默认浏览器普通标签页。

## 开发与验证

离线测试使用临时目录和模拟下载，不修改真实安装，也不会启动服务或浏览器窗口：

```bash
bash -n dsh-window.sh
bash -n install.sh
bash tests/macos-node.sh      # 运行时选择、校验与下载回退
bash tests/macos-install.sh   # 安装器参数、文件校验与卸载
bash tests/macos-launcher.sh  # 浏览器进程归属、服务归属、托盘行为与生成的 AppleScript
powershell -File tests/windows-launcher.ps1
```

测试覆盖安装参数传递、仅创建快捷方式、无网络卸载、无效脚本/损坏图标/空文件和下载失败时保留原有文件、
Node.js 版本与架构选择，以及浏览器进程和服务归属的精确匹配。
这些用例可以在 Git Bash 或 macOS 上运行；不能据此认定 macOS 菜单栏和浏览器窗口已经通过原生验证。
`.github/workflows/verify.yml` 会在 macOS arm64、macOS Intel 和 Windows runner 上运行它们，
其中 `tests/macos-native.sh` 使用真实桌面会话：编译并启动菜单栏小程序、派发菜单回调，
并用真实的 Node 进程验证认证地址恢复、重启和停止。

在真实 macOS 桌面会话中，安装后可检查菜单栏编译与启动；该检查不会安装 Node.js 或启动 dsh 服务：

```bash
bash "$HOME/Library/Application Support/dsh-shortcut/dsh-window.sh" --no-sync --self-test
```

还需人工确认：Intel/Apple Silicon 运行时、Node.js 目录选择与取消回退、浅色/深色菜单栏图标、左键唤回窗口、
右键菜单各项、关闭窗口后服务继续运行、重复启动仅一个图标、Exit 停止服务，以及卸载保留 `~/.dsh` 和外置 Node.js。
本次 Windows 开发环境中的离线检查不构成这些原生 macOS 场景的实机验证。

## 许可

MIT

DeepSeek Harness 由 DeepSeek AI 开发，以 MIT 许可发布；本项目是它的 Windows 和 macOS 启动封装。
