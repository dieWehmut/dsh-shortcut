<h1 align="center">dsh-shortcut</h1>

<p align="center">
  Run <a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a> in its own application window on Windows.
</p>

<div align="center">

[![Windows](https://img.shields.io/badge/Windows-10%2B-0078D4?style=flat-square&logo=windows)](https://www.microsoft.com/windows)
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
3. 用 Edge/Chrome 的**应用模式**（`--app=`）打开独立窗口，并写入开始菜单和桌面快捷方式

同时，如果电脑上还没有满足要求的 Node.js，脚本会**自动下载适配本机架构的
Node.js 运行时**安装到安装目录（校验官方 SHA256，不需要管理员权限，也不改动系统
PATH）。

每次启动还会自动和仓库比对启动器与图标，有更新就替换并立即用新版本重启（见「自动同步」）。

原有的 `~/.dsh` 数据（会话、设置、凭据）完全保留，脚本不修改 dsh 安装本身。

## 一键安装

在 PowerShell 里运行：

```powershell
irm https://raw.githubusercontent.com/dieWehmut/dsh-shortcut/main/install.ps1 | iex
```

安装完成后，桌面和开始菜单会出现 **DeepSeek Harness** 快捷方式，双击即可打开独立窗口。

## 自动同步

每次启动都会把本机的启动器和图标与仓库内容做一次比对，有差异就替换，然后用新版本继续本次启动。所以仓库里发布的修复不需要重新安装就会到达这台机器。

- 比对的是内容（SHA256），不是版本号，只看仓库 `main` 分支
- 更新后的文件立即生效：脚本会用原参数重启一次，这次重启只发生一次
- 从源码目录直接运行时只更新本机安装，不会重启（避免打断开发中的调试）
- 断网、仓库 404 或返回空文件时保持本机副本，启动照常继续
- 仓库里的启动器语法不通过时拒绝安装，本机副本继续可用
- 想跳过这次比对：加 `-NoSync`

## 环境要求

- Windows 10 或更高
- PowerShell 5.1 或更高（系统自带）
- **Node.js 22.19+ 或 24+**，没有也可以：脚本会自动安装（见「自动安装 Node.js」）
- Edge 或 Chrome（用于应用窗口模式；两者都没有时会退回默认浏览器的普通标签页）

脚本只影响当前用户，不需要管理员权限。

## 自动安装 Node.js

启动时会先找可用的 Node.js（22.19+，或 24+）：

1. 已安装且版本满足要求 → 直接使用（包括安装到自定义目录的，按注册表记录定位）
2. 安装了但版本过旧，或完全没有 → 弹出 **Node.js 官方安装向导**，可以自己选择安装位置
   和选项；下载后的安装包与官方 SHA256 校验一致才运行（x64 / arm64 / x86 自动识别，
   nodejs.org 不通时自动改用 npmmirror 镜像）
3. 向导被取消、UAC 被拒绝，或没有可交互桌面（无人值守）时 → 自动回退为原来的免管理员
   便携安装：解压到 `%LOCALAPPDATA%\dsh-shortcut\node\`，不写系统目录、不改系统 PATH

想跳过向导直接静默安装：加 `-SilentNodeInstall`。

## 使用

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

> 注意：便携运行时会随 `-Uninstall` 一起删除（它就在安装目录里）；用官方安装向导装的
> Node.js 是系统级安装，卸载脚本不会动它，需要的话请从「应用和功能」里卸载。

### 卸载

```powershell
& "$env:LOCALAPPDATA\dsh-shortcut\dsh-window.ps1" -Uninstall
```

## 自定义

### 模型与 API Key

打开窗口后在 **Settings → Models** 里填 API Key 并选择模型，设置保存在 `~/.dsh/settings.yaml` 与 `~/.dsh/.credentials.yaml`，下次启动自动生效。

也可以放在环境变量或 `.env` 里（优先级：进程环境变量 > `.credentials.yaml` > 当前目录 `.env` > `~/.dsh/.env`）：

```powershell
[Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', 'sk-...', 'User')
```

### 固定端口和浏览器

修改快捷方式的目标参数即可，例如把 `-Port 8080 -Browser chrome` 追加到参数末尾。

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
脚本要求 22.19+ 或 24+（与 dsh 的 `engines` 范围一致）。会自动弹出 Node.js 官方安装
向导；向导里取消或拒绝 UAC 时会自动改用便携安装，两个下载源（nodejs.org 与 npmmirror）
都失败时按提示到 [nodejs.org](https://nodejs.org/) 手动安装后重试。

**安装向导弹出来后没反应 / 想装到别的盘**
向导就是 Node.js 官方安装程序，按自己的需要选择安装位置即可，装完脚本会自动找到它
（按安装包写入注册表的路径定位，不依赖 PATH）。如果向导没弹出来，可能是这台机器不允许
弹窗（无人值守会话）：脚本会自动转为便携安装。

**首次运行很慢**
首次要下载约 500 个 npm 包，通常 1–3 分钟（视网络情况可能更久）。之后启动只需几秒。

**想用系统默认浏览器而不是 Edge/Chrome**
把 `-Browser` 指向别的 Chromium 系浏览器，或者删掉快捷方式参数里的 `-Browser` 并确保系统里没有 Edge/Chrome —— 脚本会退回默认浏览器普通标签页。

## 许可

MIT

DeepSeek Harness 由 DeepSeek AI 开发，以 MIT 许可发布；本项目只是它的 Windows 启动封装。
