# Swivel

A native, local file toolkit for macOS. Drag any file, tap a key, and drop it on the wheel that appears under your cursor.

## Download · 下载

| Your computer · 你的电脑 | Download · 下载 |
| --- | --- |
| **Mac** — macOS 15 or later, Apple silicon (M1 or newer) · Apple 芯片 | **[⬇ Download for Mac · 下载 Mac 版](https://github.com/xichengchen1111-hub/swivel-mac/releases/latest/download/Swivel-mac.zip)** |
| **Windows** | Preview in progress, not available yet · 预览版准备中，暂不提供下载 |

Not sure which Mac you have? Apple menu → About This Mac: "Chip: Apple M…" means Apple silicon. On an Intel Mac, build it yourself (see below). Older versions are on the [Releases](https://github.com/xichengchen1111-hub/swivel-mac/releases) page.

不确定是哪种 Mac？点左上角苹果菜单 →「关于本机」，「芯片」写着 Apple M… 就是 Apple 芯片。

**First time opening it?** macOS will block it once — see [step 4 below](#download-and-install). · **第一次打开被拦？** 看下面的[安装第 4 步](#download-and-install)。

| Key while dragging | Wheel |
| --- | --- |
| ⇧ Shift | **Convert** formats |
| ⌘ Command | File **tools**: editors for Crop, Compress, Edit (exposure, colour…), Add Background, Remove BG (local transparent PNG cutout), Redact (finds faces and text on-device), Metadata and Annotate (arrows, boxes, text, numbered callouts); Collage for several images; Trim for video and audio; Merge for several videos or audio files; plus resize, rotate, mute, split… |
| ⌃ Control | File **actions** (Batch Rename, AirDrop, Float shelf, Copy, Move, Copy Path, Terminal) |
| ⌥ Option | **Apps**: configured applications, Codex and Claude Code drafts |
| fn | **Codes**: QR library and saved codes |

Tap the same key again to page through a wheel that has more than eight options. Drop on the centre to cancel. Results are saved next to the original — no new folders, even for multi-page PDFs or archives. Click the toast to reveal them in Finder.

### How it feels

- The option under the pointer **springs out of the ring**, and a dial on the hub turns to it. Moving on lets it settle back while the next one comes out, so a quick sweep reads as one wave. Selection follows the pointer's direction, so overshooting past the ring keeps the option you aimed at, and a little hysteresis stops it flickering at the edges.
- **Dropping presses the option in**, holds it for a beat and lets it spring back as the rest of the menu clears away; the file's icon flies into it. A Force Click while still dragging pushes the option partway in first.
- Coming back to the centre shows **Cancel**; releasing there (or pressing Esc) clears the menu at once.
- On a Force Touch trackpad each new option gives a light **detent**, a page turn a step, and the drop a firmer **press**. Optional **sound effects** (a soft tick per option, a ratchet for pages, a key “thock” on the drop and a short chime when a result is saved) follow the system's “Play user interface sound effects” setting. Both have switches in General and in the ◎ menu.
- Reduce Motion keeps the colour and feedback but nothing moves; Reduce Transparency puts a solid backdrop behind the wheel.

Media processing runs locally, using macOS frameworks (Core ML, Vision, ImageIO, AVFoundation, PDFKit, AppKit text system) and `afconvert` / `ditto` / `tar`. Upscale includes a pinned Real-ESRGAN model, and Mac Doctor includes vendored cache data (see Acknowledgements). Neither sends files to a service.

## Download and install

Requires macOS 15 or later. The prebuilt download is for Apple silicon Macs; on an Intel Mac, build it yourself (below). Some features need macOS 26.

1. Download **Swivel-mac.zip** (link above) and unzip it.
2. Move `Swivel.app` to Applications.
3. Open it once. Swivel isn't notarized by Apple yet, so macOS says it can't verify it ("Apple could not verify…"): click **Done** (not Move to Trash).
4. Open **System Settings → Privacy & Security**, scroll down to *"Swivel" was blocked*, click **Open Anyway** and confirm with your password. You only do this once.

   第一次打开时 macOS 会提示「Apple 无法验证 "Swivel"…」：点 **完成**（不要点「移到废纸篓」），然后打开 **系统设置 → 隐私与安全性**，滚到最下面，在「已阻止使用 "Swivel"」旁点 **仍要打开**，输入密码确认。只需要做一次。（macOS 15 起，按住 Control 点「打开」已经不能绕过这个提示。）

To build it yourself instead, install the Xcode Command Line Tools and run `./build.sh` (the app appears in `build/Swivel.app`); `./test.sh` runs the automated checks.

## Licence

Swivel is **source-available, not open source**: you may read the code, download it, build it and use it for yourself, but you may not modify it, redistribute it or use it commercially. See [LICENSE](LICENSE). Third-party parts under `ThirdParty/` keep their own licences. Pull requests are not accepted; bug reports in Issues are welcome.

## The app window

Swivel is a bundle of eleven tools, each switched on or off on its own — from the app window (open Swivel from Launchpad or Finder, or **Open Swivel…** in the ◎ menu) or straight from the ◎ menu. Optional tools start **off**, so each user can choose what to enable.

The window works like PowerToys: features in a sidebar, each page starting with the feature's switch.

- **Overview**: all eleven features with their switches.
- **Wheel**: the drag-and-tap menu. Sections for **Shortcuts** (which key, ⇧ ⌘ ⌃ ⌥ fn, opens each menu), **Style** (Wheel, List, Bookshelf, Sticky Notes, Clothesline templates) and **Customize** (which options each menu shows per file type, and their order; drag a row by its grip to reorder). Bookshelf, Sticky Notes and Clothesline use quiet, nearly neutral card surfaces, fine borders, light shadows and system text, with matching dark appearances. The menu previews are live: move the pointer over one to try how it feels, and click an option to press it.
- **Clothesline**: a rope under the menu bar. A new screenshot first waits as a card in the bottom-right corner, like the system thumbnail: drag it up (or click it) to hang it, drag it into an app or folder like any file, or leave it and it goes to your usual screenshot folder. The rope and prints move on a small physics model (spring drop, pendulum swing, breeze); move the pointer to the screen’s top edge (or press ⌃⌥T) to lower it immediately. Click to copy (the print confirms it with a “Copied” chip), double-click to open, hold or Force Click for Quick Look (it zooms out of the print), drag into an app for a copy or into a folder to take it down, drag to the Trash or click × to discard. Clicking the corner card flies it up to its peg. A rope shown with ⌃⌥T stays until you click elsewhere. The motion is deliberately calm: everything is well damped and settles within about a second. Images can also be hung from the Wheel's ⌃ Actions menu. Unattended screenshot cards slide away after 2.5 seconds; hovering or dragging pauses dismissal, and leaving the card gives you another second. The screenshot is kept in your usual screenshot folder.
- **Stitch on the Clothesline**: drag a hung still image over the centre of another and hold briefly (0.25 s). A spring preview shows the target above the dragged image; release to save a new PNG, or move away to cancel. The two prints are replaced on the rope for this session, while their files stay unchanged beside the result. Drag the result onto another print to continue. Images match the narrower width without cropping or enlargement; transparency is retained. This joins whole images, without automatic overlap removal. Animated/multi-page, HDR/auxiliary and high-bit-depth inputs are refused; source pixels total at most 40 MP (less on low-memory Macs), and the result is at most 32,768 pixels on either edge. Normal Finder/card drops still hang files.
- **Soft photo stitching**: overlapping prints gather with a liquid waist, a small squash and one gentle rebound. Moving away reverses the preview; release holds it while processing and passes its position to the new print. A wider exit area tolerates small pointer movements. Reduce Motion uses static shapes and no travel.
- **Template colors**: Wheel → Colors provides separate Bookshelf and Sticky Notes palettes. Choose Soft Neutrals, Misty Coast, Sage Garden, Warm Linen, Rose Clay or Lavender Haze, or customize four repeating colors with native color wells. The Bookshelf rail has its own color well. Live previews, per-template reset, automatic persistence and readable light/dark text are included.
- **Ready to drop**: dragging an accepted screenshot/image over the rope makes the cord clearly blue, thicker and softly glowing, so you know you can release. Leaving restores the chosen rope color; the cue also works with Reduce Motion and only appears when the source permits a supported drop operation.
- **Clothesline colors**: choose the rope and peg colors independently on the Clothesline page. Six muted presets (Silver, Graphite, Sand, Sage, Mist Blue and Dusty Rose), a native custom-color picker, a preview and Reset rope colors are included. Choices save automatically and update existing hung prints as well as the Clothesline menu template.
- **Text Capture**: choose an image and extract English, Chinese or Japanese text locally with Apple Vision. Review or edit the result, then copy it (⌘Return copies while you edit). Also available in the Wheel's Tools menu for one image and the Clothesline photo's contextual menu. It reads selected image files; it does not capture the screen.
- **File Shelf**: gather files and folders in a floating native list. Command-click or Shift-click to select several, then drag them out together. Space opens Quick Look. New files glide in and glow briefly; one already on the shelf is pointed out instead of added twice. Removing or clearing items only removes references (⌘Z brings them back); originals stay in place. The shelf floats without taking focus from the app you're working in. The shelf is temporary and clears when Swivel quits.
- **Image Presets**: save a name, maximum long edge, JPG/PNG/HEIC/TIFF format, quality and metadata preference. Three built-in presets are included. Apply a preset to one or several images from Settings, the Wheel or Quick Actions. Results are written beside each original with unique names. Small images are not enlarged; JPG composites transparency onto white. Animated images use their first frame. Turning the feature off retains saved presets.
- **Quick Actions**: press **⌃⇧Space** to search enabled tools without finding the menu-bar icon. Choose files or drop them onto the panel, search, use ↑/↓, and press Return; the chosen row blinks as it runs, like a menu. Esc dismisses the search panel. It appears instantly and doesn't take Swivel to the front. Settings offers **⌃⌥K** and **⌘⇧P** as alternatives and reports shortcut registration conflicts. It accepts explicitly supplied files rather than reading the selection in another app.
- **Batch Rename**: combine a base name, find/replace, prefix, suffix and numbering. Review every old/new name and conflict before applying. Extensions are preserved; existing files are never replaced. Undo checks that the renamed files still belong to the operation and remains available while the window is open.
- **PDF Pages**: select ranges such as `1,3-5`, reorder thumbnails, rotate or remove pages and export a selection or the whole arranged document. Results have unique names beside the original; source PDFs remain unchanged.
- **QR & Barcodes**: read selected images locally, including multiple codes and rotated images. Review text before copying or confirming a web link. Explicitly save codes in **QR Library**, with names, collections, search, add/edit/delete and undo. The library stores decoded content locally and can regenerate a QR image. Each code grows into a small 3D voxel scene (Tree, Bouquet or Island, each in spring, summer and autumn) built from the code's own modules; click it and the camera turns to look straight down, where the leaves, flowers or land line up into the scannable code. Copied/exported images always contain a plain QR code with its quiet zone.
- **App Actions**: add as many applications and web pages as you like (Word, Mail, Photoshop, an upload page…), each with optional extension filters. The app list includes apps kept one folder down, such as Adobe's. Open files through macOS, or open an app and prepare file references on the clipboard for an explicit paste. A **web page** (https, or http only to this Mac or the local network) opens in the default or a chosen browser with the files on the clipboard to paste into its upload box; nothing about the files is added to the address and nothing is uploaded until you paste. Built-in **Codex / Claude Code** actions use official deep links to open a new draft containing local file paths. They do not upload attachments or send messages. These rules affect Swivel only. Apps have individual switches as well as the feature switch.
- **My Wheel**: Wheel → Customize → Menu: **My Wheel**. Tick actions from every menu (formats, tools, file actions, apps and web pages, saved codes) and drag them into your order. Give it a key to tap during a drag (it starts with none, so it never takes another menu's key unless you pick one; picking one swaps) and optionally record a keyboard shortcut (⌘, ⌃ or ⌥ plus a key; macOS and other Swivel shortcuts are reported as conflicts). During a drag it shows only the picked actions that fit the file; opened by the shortcut, it lists them all and asks for files when one is chosen.
- **Shortcut wheel**: enable **Wheel → Shortcuts → Shortcut wheel**, then press **⌃⌥J** (alternatives: ⌃⌥Space / ⌃⌥W). Click an item or use arrows and Return; Space changes pages and Esc closes. It uses the selected wheel template. Batch Rename, PDF Pages, Scan QR, QR Library and Apps appear according to their switches. Apps open a submenu; QR Library opens its window directly; file tools ask you to select files. No Finder selection is read implicitly. Existing custom drag-key assignments are preserved when the two new wheels are added.
- **Feel & Text** (also available directly in the ◎ menu): five presets — Original, Calm, Snappy, Playful and Quiet — plus independent speed (0.75–1.5×) and bounce controls for pop-up menus, the Clothesline and tools/settings. Try all five menu layouts in a live preview or replay a local motion sample. Choose Classic, Soft or Bright sounds, set their level relative to the system effects volume, mute selection sounds separately, or use gentler trackpad taps. Selection, page, confirm and completion buttons let you try feedback. Four text sizes (Small through Extra Large) and bold text update native windows and menu labels immediately; exported-image lettering is unchanged. Changes persist automatically, custom tuning is identified, and Restore tuning defaults resets this page. Presets preserve text choices and the existing sound/haptic on/off switches; macOS Reduce Motion and sound settings still take priority.
- **Keep Awake**: stop the Mac from idle sleep for 30 minutes, 1, 2 or 5 hours, or until turned off — from the ◎ menu (the ring fills while it's on), its settings page or Quick Actions. Choose whether the display stays on too. It uses a standard power assertion: no permission, and it ends when the time is up, when you stop it or when Swivel quits. Closing a laptop's lid still sleeps it.
- **Quick Actions assistant** (optional, off until you add a key): in Quick Actions → Assistant, choose Claude (Anthropic) or any OpenAI-compatible service (DeepSeek, Qwen, a local Ollama server) and save your own API key; it is stored in the login keychain. Type a request such as “make these photos smaller than 1 MB” and choose **Ask the assistant**: the model picks one of the enabled actions, which appears first in the list with a short explanation, and runs only when you press Return. Swivel sends the request, the action names (your own preset and app names included; saved QR codes are left out because they are named after images) and the kinds of chosen files — never file names, paths or contents — and accepts only an action that was offered. A key belongs to the address it was saved for, and redirects are never followed, so it can't be sent anywhere else.
- **Mac Doctor** (off by default): finds out why the Mac is full, slow or won't open an app, and only reads. Its window has a **Summary** and one area per problem: **Storage** (free and purgeable space, local Time Machine snapshots behind "System Data", simulators, Xcode archives), **Caches** (up to 45 caches that rebuild themselves, each with what moving it removes and keeps; Safari's is listed by ClearDisk but macOS protects it), **Folder Sizes** (a folder you pick, this session only), **Slow or Hot** (busiest and largest processes including system ones, memory pressure, swap, heat, uptime, with plain explanations for kernel_task, Spotlight, Photos analysis…), **Apps That Won't Open** (signature, Gatekeeper verdict, notarization, the downloaded flag, Intel-only, minimum macOS, iPhone apps), **External Drives** (formats such as NTFS read-only, drives that aren't mounted, Eject with the app that blocks it), **Network** (DNS source, proxy apps, an optional Apple speed test), **Background Items** (launch agents and daemons, leftovers of removed apps, disguised names) and **Battery & Sleep** (capacity, cycles, apps keeping the Mac awake). Fixes run only after you choose and confirm them: caches or your own leftover launch agent go to the Trash as one folder per item, with **Undo Last Move**; Eject; or the exact System Settings pane. Commands that need an administrator are shown collapsed with an explanation and a Copy button, never run. It needs no new permission (protected places like Documents, Mail or other apps' data are skipped, cloud-only files are never downloaded) and uses the network only for Test Speed, App Check's notarization lookup and, if you turn it on, **Ask the Assistant**, which shows the exact redacted text (facts only; names only if you tick the box) before sending it.
- **General**: open at login, haptic feedback, sound effects (feature switches click like a light switch), language.

The editors snap where it helps: crop edges catch the image edges, the centre lines, the thirds and the original ratio, sliders have a detent at their neutral value and reset on double-click, Trim handles stop at the ends, and Annotate arrows catch 45° steps with ⇧. Hold ⌘ while dragging to turn snapping off. Redact waits for its face and text search before saving, and won't write a “redacted” copy with nothing covered. Press and hold the preview in Edit or Compress to compare with the original. Each catch is a light tap on a Force Touch trackpad.

**Remove BG** cuts the subject out with Apple Vision and saves a transparent `name cutout.png` beside the original (several images at once work too). **Compress** for images has a **Target size** (100 KB – 5 MB): the quality, then if needed the dimensions (never below 320 px on the long edge), are chosen automatically, and an unreachable target says so instead of saving a larger file. **Compress** for video first asks for a target — a smaller file, or 8 / 10 / 25 / 50 / 100 MB — and re-encodes to H.264/AAC with one corrective pass; the result message states the final size. **Trim** cuts video exactly (re-encoded), so frames before the start point don't remain hidden in the file.

The new tools use AppKit windows, sheets, sidebars, SF Symbols, system colours and native controls, with light/dark appearance support. Their UI is available in English, Simplified Chinese, Traditional Chinese and Japanese. They require no Accessibility, Screen Recording or Full Disk Access permission.

## Formats

- **Images**: JPG, PNG, HEIC, TIFF, AVIF, GIF, BMP, PDF (WebP is read but only written where macOS supports it)
- **Video** (MOV/MP4/M4V): MP4, MOV, HEVC, M4V, GIF, M4A, WAV, PNG frame
- **Audio**: M4A, WAV, AIFF, FLAC, ALAC, CAF, AAC
- **PDF**: PNG / JPG pages at 300 DPI, TXT, DOCX, RTF, HTML
- **Documents** (DOCX, DOC, RTF, ODT, HTML, TXT, Markdown): DOCX, PDF, RTF, TXT, HTML, ODT, DOC
- **Archives**: ZIP / TAR.GZ any file or folder; extract ZIP, TAR, TGZ/GZ, RAR (including multi-part .partN.rar and .r00 sets), 7Z, XZ, BZ2, ISO, XAR, CAB, LZH and CPIO with the system's own `tar`. Extracted files keep the archive's “downloaded from the internet” flag so Gatekeeper still checks them; extraction stops before it would fill the disk; encrypted archives are reported rather than prompted for. Disk images (DMG) are left to macOS.

## Build

```bash
./build.sh
open build/Swivel.app
```

Requires macOS 15+ and the Xcode command-line tools. It lives in the menu bar (◎ icon), where you can enable *Open at Login*.

For testing without dragging: `Swivel --run <convert|tools|actions> "<item>" <file>...`, or open an editor directly with `Swivel --edit <crop|compress|edit|bg|redact|metadata|annotate|collage|trim> <file>`.

## Use Swivel from AI agents (MCP)

`Swivel --mcp` is a local [Model Context Protocol](https://modelcontextprotocol.io) server, so Claude Desktop, Codex, Cursor, Raycast and other MCP hosts can use Swivel's converters and file tools. The installed app accepts this one argument. It talks over stdin/stdout only (no network port), speaks both the 2025 handshake and the stateless 2026-07-28 revision, and needs no extra permission: the host starts it, so macOS attributes file access to the host.

**Set up.** Settings → General → **Agents**:

- **Install in Claude Desktop** opens the extension that ships in the app (`Swivel.app/Contents/Resources/Swivel.mcpb`) with Claude, which asks to install it; the installed extension stays across restarts. Its launcher starts the Swivel installed in /Applications, ~/Applications or on the Desktop rather than carrying a copy of it. Without Claude.app (or an installed Swivel) the button copies the JSON below instead.
- **Copy Claude Code Setup** copies the Terminal command for Claude Code (user scope, so every project sees it).
- **Copy Codex Setup** copies the lines for `~/.codex/config.toml`.

By hand, for Claude Code and Codex:

```bash
claude mcp add --scope user swivel -- /Applications/Swivel.app/Contents/MacOS/Swivel --mcp
```

```bash
codex mcp add swivel -- /Applications/Swivel.app/Contents/MacOS/Swivel --mcp
```

Cursor (`~/.cursor/mcp.json`), Raycast and other hosts take the same command and argument:

```json
{ "mcpServers": { "swivel": { "command": "/Applications/Swivel.app/Contents/MacOS/Swivel", "args": ["--mcp"] } } }
```

`Swivel --mcp` hands over at once to a background-only helper inside the app (`Contents/Helpers/Swivel MCP.app`, same pid), so a running server never stands in for Swivel.app: Finder and the Dock still open the menu-bar app while a host keeps the server open. Point hosts at the main executable as above, not at the helper.

Claude Desktop's `claude_desktop_config.json` takes the same entry, but only while Claude is quit: a running Claude rewrites that file from memory and drops an entry added meanwhile (seen on 2026-10-22), so prefer the extension. `./build.sh` packs it into the app; `./mcpb/pack.sh [output]` builds it alone (default `build/Swivel.mcpb`, an MCPB bundle with `server.type: "binary"`), and `open -a Claude build/Swivel.mcpb` installs it.

**Tools.**

| Tool | Does |
| --- | --- |
| `list_actions` | What the files can become: `convert.*` / `tools.*` ids from the wheel's catalog (formats, Remove BG, resize, rotate, merge, split, ZIP, extract…). Editors that need a window are not offered |
| `inspect_files` | Kind, size, dimensions, PDF pages, word count, duration |
| `extract_text`, `read_codes` | On-device OCR and QR/barcode reading for images |
| `plan_action`, `plan_compress`, `plan_rename`, `plan_move` | Validate and predict: the exact files that would be created, renamed or moved. No side effects |
| `apply_plan` | Carries out a plan once, within an hour, and only if its inputs haven't changed since |
| `undo`, `history` | Reverse an applied plan (created files go to the Trash; renames and moves go back, unless something changed since) and list past ones |

Paths must be absolute, plain (no `.`/`..`), existing regular files or folders, and not symbolic links themselves. Outputs follow the usual rules: next to the original, numbered instead of overwriting. The undo log is `~/Library/Application Support/Swivel/Agent History/history.json` (owner-only, last 200 changes). A development build can use another folder with `SWIVEL_MCP_HISTORY_DIR`; the installed app ignores it.

Try it by hand:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"shell","version":"1"}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | .build/debug/Swivel --mcp
```

## Validate the new tools

```bash
./test.sh
.build/debug/Swivel --recognize /path/to/image.png
.build/debug/Swivel --tool text /path/to/image.png
.build/debug/Swivel --tool shelf /path/to/one.png /path/to/two.txt
.build/debug/Swivel --tool quick /path/to/image.png
.build/debug/Swivel --tool presets
.build/debug/Swivel --tool feel
.build/debug/Swivel --tool rename /path/to/one.txt /path/to/two.txt
.build/debug/Swivel --tool pdf /path/to/document.pdf
.build/debug/Swivel --tool qr /path/to/code.png
.build/debug/Swivel --tool library
.build/debug/Swivel --tool apps
.build/debug/Swivel --tool launcher
.build/debug/Swivel --tool doctor /Applications/Some.app
```

`test.sh` runs 234 Swift Testing checks (one of them, `DoctorLiveTests`, only does something with `SWIVEL_DOCTOR_LIVE=1`) for image output safety, metadata and orientation, preset validation, shelf references, feature gating/search, OCR, hotkeys, interaction feel and settings persistence. Coverage includes rename conflicts, rollback/undo, PDF order/rotation and original preservation, QR decoding and library persistence, draft links, app routing, independent switches, wheel shortcuts and the MCP server (protocol, plan/apply/undo, path checks, no network listener). Mac Doctor's checks cover its fixed command set (an exhaustive allow-list), the capturing runner (large output, timeouts, cancellation), Trash moves (links, swapped folders, changed items, undo without overwriting), protected places, launch-agent and App Check edge cases (FIFOs, `..` executables, revoked or self-signed apps, echoed paths), parsers against real output shapes, redaction, the assistant request, gating, layouts in four languages and every text size, and translations. It uses the macro plugin bundled with the selected Swift toolchain when available; no package dependencies are downloaded.

`--tool` is a UI preview mode that enables the optional tools **in that executable's preferences domain**, registers the Quick Actions shortcut and skips the normal app delegate, screenshot takeover and background watchers. Use the unbundled debug executable or a separate validation bundle, not the installed production app. `--recognize` prints OCR results without changing the clipboard or feature preferences.

Set `SWIVEL_PREVIEW_APPEARANCE=light` or `dark` with `--tool` to inspect the two appearances without changing macOS settings.

Quit the running app normally before replacing an installed build, so screenshot settings can be restored. New output files never replace originals.

`SWIVEL_TAB=10` opens Feel & Text in the normal app. `--tool feel` previews that page without screenshot watchers; use a separate validation bundle. `SWIVEL_TUNING_RENDERS=/path ./test.sh` exports light/dark tuning-page renders at every text size.

`SWIVEL_QR_LIBRARY_DIR=/temporary/test-library` isolates the QR library in `--tool` previews. `SWIVEL_FILE_ACTIONS_RENDERS=/path ./test.sh` renders every template and season and decodes each top view with Vision; `SWIVEL_QR_FILMSTRIP=/path` renders the camera turn and times scene building. File results are regenerated from decoded content rather than copies of the original QR artwork. The scene-to-code interaction was inspired by [Tree.ICQR](https://tree.icqr.com/) and independently built with SceneKit; no source or assets were copied.

`SWIVEL_TAB=17` opens Mac Doctor's settings page. `SWIVEL_DOCTOR_RENDERS=/path ./test.sh --filter DoctorTests` renders its page and the Overview in four languages, the window's Summary and Caches in four languages and every window section in Simplified Chinese, light and dark. `SWIVEL_DOCTOR_LIVE=1 ./test.sh --filter DoctorLiveTests` runs every read-only check against this Mac and prints the results (no speed test, no Eject, nothing moved).

## Acknowledgements

- Upscale uses [Real-ESRGAN x4plus](https://github.com/xinntao/Real-ESRGAN), Copyright (c) 2021 Xintao Wang, BSD-3-Clause. The included model runs through Apple Core ML on macOS 15+; it reconstructs textures and may change small details. Its provenance and reproducible conversion are in `ThirdParty/RealESRGAN/UPSTREAM.md`. Conversion-only RRDB code comes from BasicSR (Apache-2.0); conversion tools are not shipped. The model licences and notice ship inside the app.

- Mac Doctor's cache list (paths and "removes / keeps / note" texts) comes from [ClearDisk](https://github.com/bysiber/cleardisk) by Kadir Can Ozden, MIT License, revision `fb5429c`. See `ThirdParty/ClearDisk/` (`LICENSE`, `UPSTREAM.md`); the licence also ships inside the app.
- Mac Doctor's space map, duplicate files, project build folders and app uninstalling follow the feature ideas of [MangoDisk](https://github.com/harry0703/MangoDisk) by harry0703. MangoDisk is GPL-3.0, so only its feature list was used: Swivel's implementation is written from scratch, and none of its code, rules or artwork is included.

Draft-link references: [Codex commands](https://learn.chatgpt.com/docs/reference/commands) and [Claude Desktop links](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link).

Version 1.4.1 adds **Add Application…** directly to Wheel → Customize → App Actions, with a link to manage existing rules. Previewing a category now includes all configured extensions in that category (for example TXT alongside DOCX). The shortcut wheel defaults to **Control + Option + J**, checks enabled macOS shortcuts before reporting readiness, and reports a conflict for Control + Option + Space when it is assigned to input-source switching. Space alone is for paging an already open wheel. The QR library has an explicit empty-state New/Import flow; imports report empty and duplicate results, and new/imported codes clear stale search filters.

Version 1.6.0 adds **Mac Doctor** (read-only diagnostics with confirmed, undoable fixes; ClearDisk's MIT cache catalogue) and the **MCP server** (`Swivel --mcp`, plan → apply → undo for agents such as Claude Desktop and Codex), and makes every writer, move and rename claim its name exclusively, so two operations at once can never replace each other's files.

Version 1.5.0 adds Remove BG, target-size compression for images and video, RAR/7z/ISO extraction, Keep Awake and the optional Quick Actions assistant, and fixes the issues found in a security review: outputs are never written through a symlink planted at the output name; tools can't hang on a full error pipe or a password prompt; extraction keeps the quarantine flag and stops before filling the disk; file names that look like options are archived, not obeyed; web archives and HTML no longer pull in remote or local resources; metadata removal is verified by reading the result back; Redact's blur and mosaic scale with each box; movies that reference other files are refused; Codex/Claude Code drafts show hidden characters in file names; the installed app is signed with the hardened runtime and ignores the developer command-line modes, which remain available to unbundled builds and validation bundles.

Version 1.4.2 fixes screenshot takeover becoming inactive while its switch stayed on. Applications and Desktop copies now reuse a single running instance. Screenshot settings have a process owner, so a stale process cannot undo the current owner's takeover; the original settings survive recovery/restart. Reopening or waking the active app checks and repairs its enabled takeover. Quitting preserves a destination explicitly changed in the system screenshot toolbar. New screenshots first appear as a card: click it or drag it up to hang it; unattended cards still go to the original screenshot folder.


### File safety and conversion fidelity (2026-10-23)

- Generated files are written inside a private temporary directory and published only after completion, without replacing an existing file or link. On file systems supporting POSIX permissions/ACLs, generated outputs default to owner-only access. Copy operations preserve source attributes; archive extraction restricts top-level access while preserving executable bits.
- Move to… moves within one volume. Across disks it explicitly **copies and keeps the original**; screenshot saves fall back to the local rope folder. This prevents deletion of a newer source saved by another app during a copy.
- ZIP extraction verifies every entry against the same private snapshot it extracts. New ZIP/TAR archives are verified before publication. ZIP supports Mac resource forks and extended attributes for both single and multiple selections. TAR creation refuses custom Mac metadata; TAR extraction refuses AppleDouble metadata it cannot safely restore. Use ZIP, or Archive Utility for an existing Mac-metadata TAR.
- Archives leave at least approximately 1 GB free, have a 10-minute processing watchdog, and stop at 100,000 extracted entries or 100 GB of logical content. Checks are periodic during extraction and repeated before publication. They do not guarantee survival of a sudden power loss or a disk filling faster than the watchdog.
- TIFF pages convert to separately numbered images. Animation and unsupported auxiliary/HDR data are refused in still-image operations. Format conversion preserves supported colour profiles, orientation and metadata; high-depth PNG/TIFF avoid the 8-bit preview path. Ordinary editing rejects precision it cannot retain. JPG/HEIC and other lossy formats remain lossy; JPG/BMP flatten transparency to white.
- Compatible MOV/MP4/M4V format-only changes use stream copying. Edits and trims still re-encode. Video-to-WAV decodes directly to float32 PCM without an AAC intermediate; audio beyond that precision is refused. WAV/AIFF/CAF preserve supported source precision, sample rate and channels; lossless conversions validate these and the frame count. Float audio is not silently converted to integer FLAC/ALAC.
- GIF export covers the selected clip, up to 30 seconds, at 12 fps and up to 540 pixels; longer videos require Trim. Conversion notices explain intentional losses in image, video, audio, document and PDF actions, including in MCP plan previews. Office conversion remains basic text/rich-text conversion, not a layout-preserving Office engine.
- Completed parts of a failed batch remain visible in the error result and MCP undo history. Byte budgets are 64 MiB for document imports, 256 MiB for PDF input/snapshots, and 2 MiB for assistant replies; PDF operations also enforce the existing 2,000-page cap. Image decode limits now account for machine memory, up to 120 megapixels.

