# Swivel for macOS

Native file tools in your menu bar: drag a file onto the wheel, hang screenshots on the Clothesline, or use each tool independently.

原生 Mac 菜单栏文件工具：拖动文件调用轮盘、把截图挂上晾衣绳，也可以单独启用各个工具。

## Download · 下载

**Current version · 当前版本：1.14.6 (47)**

**[⬇ Download Swivel 1.14.6 · 下载 Mac 版](https://github.com/xichengchen1111-hub/swivel-mac/releases/download/v1.14.6/Swivel-mac.zip)**

- Apple silicon Macs (M1 or newer), macOS15 or later. Some optional features require macOS26.
- 适用于 Apple 芯片 Mac，要求 macOS15及以上；部分可选功能要求 macOS26。
- [Release notes · 更新说明](https://github.com/xichengchen1111-hub/swivel-mac/releases/tag/v1.14.6) · [SHA-256 checksum · 校验文件](https://github.com/xichengchen1111-hub/swivel-mac/releases/download/v1.14.6/Swivel-mac.zip.sha256) · [Earlier release notes · 历史更新说明](https://github.com/xichengchen1111-hub/swivel-mac/releases)

Choose **Swivel-mac.zip**. GitHub’s automatically generated “Source code” ZIP/TAR files are repository snapshots, not application installers. Only the current version is offered for download. This release provides no Intel or Windows installer.

请选择 **Swivel-mac.zip**；GitHub自动生成的“Source code”压缩包不是安装包。只提供最新版本的安装包；本次不提供 Intel或Windows安装包。

## Install · 安装

1. Download and unzip **Swivel-mac.zip**.
2. Quit an older Swivel before moving the new **Swivel.app** into **Applications** and replacing it. Existing preferences and files remain outside the app.
3. Open Swivel. The app is signed locally and is not notarized by Apple. If macOS blocks the first launch, review the release and use **System Settings → Privacy & Security → Open Anyway** for this app. No terminal security changes are needed.

下载解压后，先退出旧版，再把 **Swivel.app** 放入“应用程序”替换。设置和文件不在应用包内。首次打开若被macOS拦截，可在“系统设置 → 隐私与安全性”中查看并选择对此应用“仍要打开”；无需修改系统安全设置或运行终端命令。

## What changed in 1.14.6 · 本次更新

- **Extract Text and Scan QR** now read images with more than 8 bits per channel (for example 16-bit PNG screenshots), which were refused with “convert to PNG or TIFF”. Tools that save a new picture still keep such images’ precision intact.
- **AirDrop → File Shelf** watches Downloads more calmly: a burst of changes is checked once instead of many times.
- Includes everything in 1.14.5: Mac Doctor’s live app list and Clean Up Files, and 1.14.4’s screenshot stitching.

“提取文字”和“识别二维码”现在可以读取每通道超过 8 位的图片（例如 16 位 PNG 截图），之前会提示“请转换为 PNG 或 TIFF”。会保存新图的工具仍会保护这类图片的精度。“AirDrop 进暂存架”对“下载”文件夹的检查更省电：一连串变化只检查一次。包含 1.14.5 的全部内容（Mac 医生实时应用列表、清理文件）和 1.14.4 的截图拼接。

## Source and feedback · 源码与反馈

- [Source code / Issues / PRs · 源码、问题与改进](https://github.com/xichengchen1111-hub/swivel)
- This repository publishes user-downloadable applications and release information. Current development source is maintained in **swivel**; historical files here do not represent the current release source.
- 此仓库用于向用户发布安装包和更新说明，当前源码与问题反馈统一在 **swivel**。
