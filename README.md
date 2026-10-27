# Swivel for macOS

Native file tools in your menu bar: drag a file onto the wheel, hang screenshots on the Clothesline, or use each tool independently.

原生 Mac 菜单栏文件工具：拖动文件调用轮盘、把截图挂上晾衣绳，也可以单独启用各个工具。

## Download · 下载

**Current version · 当前版本：1.14.5 (46)**

**[⬇ Download Swivel 1.14.5 · 下载 Mac 版](https://github.com/xichengchen1111-hub/swivel-mac/releases/download/v1.14.5/Swivel-mac.zip)**

- Apple silicon Macs (M1 or newer), macOS15 or later. Some optional features require macOS26.
- 适用于 Apple 芯片 Mac，要求 macOS15及以上；部分可选功能要求 macOS26。
- [Release notes · 更新说明](https://github.com/xichengchen1111-hub/swivel-mac/releases/tag/v1.14.5) · [SHA-256 checksum · 校验文件](https://github.com/xichengchen1111-hub/swivel-mac/releases/download/v1.14.5/Swivel-mac.zip.sha256) · [Older releases · 历史版本](https://github.com/xichengchen1111-hub/swivel-mac/releases)

Choose **Swivel-mac.zip**. GitHub’s automatically generated “Source code” ZIP/TAR files are repository snapshots, not application installers. This release provides no Intel or Windows installer.

请选择 **Swivel-mac.zip**；GitHub自动生成的“Source code”压缩包不是安装包。本次不提供 Intel或Windows安装包。

## Install · 安装

1. Download and unzip **Swivel-mac.zip**.
2. Quit an older Swivel before moving the new **Swivel.app** into **Applications** and replacing it. Existing preferences and files remain outside the app.
3. Open Swivel. The app is signed locally and is not notarized by Apple. If macOS blocks the first launch, review the release and use **System Settings → Privacy & Security → Open Anyway** for this app. No terminal security changes are needed.

下载解压后，先退出旧版，再把 **Swivel.app** 放入“应用程序”替换。设置和文件不在应用包内。首次打开若被macOS拦截，可在“系统设置 → 隐私与安全性”中查看并选择对此应用“仍要打开”；无需修改系统安全设置或运行终端命令。

## What changed in 1.14.5 · 本次更新

- **Mac Doctor · Slow or Hot:** a live list of apps with the memory and processor they use right now, held still while you choose, with one plain sentence about memory. Tick apps to quit them normally after a confirmation.
- **Mac Doctor · Clean Up Files** (formerly Uninstall Apps): one search finds apps you haven’t opened for months, files left by removed apps, caches (including Chrome-style browsers’ rebuildable caches), installers, duplicate copies and project build folders. They appear in foldable groups with checkboxes. Only caches and old leftovers are ticked for you; everything goes to the Trash in one step with Undo.
- Includes 1.14.4’s screenshot stitching and startup fixes.

Mac 医生“变慢或发热”改为实时列表：每个应用现在占多少内存和处理器，选择时列表不动，最上面一句话说明内存状况；勾选后确认即可正常退出。“清理文件”（原“卸载应用”）一次找出几个月没打开的应用、已删应用的残留、缓存（含浏览器缓存）、安装包、重复文件和项目构建产物，分组列出、复选框勾选，默认只勾缓存和旧残留，一键移到废纸篓并可撤销。也包含 1.14.4 的截图拼接与启动修复。

## Source and feedback · 源码与反馈

- [Source code / Issues / PRs · 源码、问题与改进](https://github.com/xichengchen1111-hub/swivel)
- This repository publishes user-downloadable applications and release information. Current development source is maintained in **swivel**; historical files here do not represent the current release source.
- 此仓库用于向用户发布安装包和更新说明，当前源码与问题反馈统一在 **swivel**。
