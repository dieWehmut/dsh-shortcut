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

原有的 `~/.dsh` 数据（会话、设置、凭据）完全保留，脚本不修改 dsh 安装本身。

## 一键安装

在 PowerShell 里运行：

```powershell
irm https://raw.githubusercontent.com/dieWehmut/dsh-shortcut/main/install.ps1 | iex
```

安装完成后，桌面和开始菜单会出现 **DeepSeek Harness** 快捷方式，双击即可打开独立窗口。

## 环境要求

- Windows 10 或更高
- PowerShell 5.1 或更高（系统自带）
- **Node.js 22.19+ 或 24+**（[下载](https://nodejs.org/)）
- Edge 或 Chrome（用于应用窗口模式；两者都没有时会退回默认浏览器的普通标签页）

脚本只影响当前用户，不需要管理员权限。

## 使用

### 快捷方式

双击 **DeepSeek Harness**。已经有一个实例在运行时，脚本会复用该实例而不是再起一个。

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

### 固定端口和风向

修改快捷方式的目标参数即可，例如把 `-Port 8080 -Browser chrome` 追加到参数末尾。

## 工作原理

`dsh web` 本身只调用系统默认浏览器打开一个标签页。这个脚本改为：

1. 用 `--no-open` 启动服务，从启动日志里读出带一次性 token 的地址
2. 把这个地址交给 Edge/Chrome 的 `--app=<url>` 模式，得到一个没有浏览器外壳的独立窗口，使用独立的浏览器配置目录
3. 窗口用一次性 token 换取签名 cookie（有效期 30 天，绑定主机和端口），之后的请求都靠 cookie 认证

官方 Web 构建自带安装元数据（`/manifest.webmanifest`，`display: fullscreen`），所以你也可以在窗口里通过浏览器菜单把它「安装为应用」，那样会得到由浏览器托管的 PWA 窗口。

## 常见问题

**窗口显示 unauthorized / 401**
已有实例的一次性 token 过期了。关掉那个服务进程，重新双击快捷方式即可。

**提示 Node 版本过低**
脚本要求 22.19+ 或 24+（与 dsh 的 `engines` 范围一致）。升级 Node 后重试。

**首次运行很慢**
首次要下载约 500 个 npm 包，通常 1–3 分钟（视网络情况可能更久）。之后启动只需几秒。

**想用系统默认浏览器而不是 Edge/Chrome**
把 `-Browser` 指向别的 Chromium 系浏览器，或者删掉快捷方式参数里的 `-Browser` 并确保系统里没有 Edge/Chrome —— 脚本会退回默认浏览器普通标签页。

## 许可

MIT

DeepSeek Harness 由 DeepSeek AI 开发，以 MIT 许可发布；本项目只是它的 Windows 启动封装。