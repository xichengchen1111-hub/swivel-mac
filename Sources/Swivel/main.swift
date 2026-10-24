import AppKit

MainActor.assumeIsolated {
    // `Swivel --mcp`, exactly, is the one mode the installed app also accepts: the agent tool server (MCPServer.swift).
    // An MCP host (Claude Desktop, Codex…) starts it as its own child and talks over stdin/stdout, so the host
    // already holds the file access, and macOS attributes it to the host, not to Swivel. The server only touches
    // the absolute paths the host passes (checked in MCPPaths), changes files only through a plan the host then
    // applies (the menus' own converters: new files next to the originals, numbered rather than replacing; renames
    // and moves that can be undone), listens on no port and reads no other arguments. It refuses to run when
    // launchd is its parent (`open`), where Swivel itself would be the process macOS holds responsible.
    if MCPStdio.isRequested(CommandLine.arguments) {
        MCPStdio.handOffToHelper()
        MCPStdio.run()
    }
    // The helper bundle is for the server only: no menu-bar app and none of the developer modes.
    if MCPStdio.isHelper { exit(64) }
    let app = NSApplication.shared
    AppTypography.install()
    let delegate = AppDelegate()
    // The developer modes below (--tool, --run, --recognize…) are for unbundled builds and validation bundles. The
    // installed app ignores them, so another process can't use them to act with Swivel's file access or to switch
    // features on in the real preferences.
    let args = Bundle.main.bundleIdentifier == "local.swivel.app" ? Array(CommandLine.arguments.prefix(1)) : CommandLine.arguments

    // Isolated preview: no screenshot takeover or background watchers. Uses the executable's defaults domain.
    if args.count >= 3, args[1] == "--tool" {
        if let directory = ProcessInfo.processInfo.environment["SWIVEL_QR_LIBRARY_DIR"] { QRLibraryStore.previewDirectory = URL(fileURLWithPath: directory, isDirectory: true) }
        for feature in [Feature.textCapture, .shelf, .imagePresets, .quickActions, .batchRename, .pdfPages, .qrCodes, .appRouting, .doctor] { Prefs.setFeatureEnabled(feature, true) }
        app.setActivationPolicy(.regular)
        app.mainMenu = AppWindow.mainMenu()
        if let appearance = ProcessInfo.processInfo.environment["SWIVEL_PREVIEW_APPEARANCE"] {
            app.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        QuickActions.shared.syncSettings()
        ShortcutWheel.shared.sync()
        CustomWheelLauncher.shared.sync()
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuickActions.shared.syncSettings(); ShortcutWheel.shared.sync(); CustomWheelLauncher.shared.sync() }
        }
        switch args[2] {
        case "text":
            if args.count >= 4 { TextCaptureWindow.present(URL(fileURLWithPath: args[3])) }
            else { AppWindow.shared.show(.textCapture) }
        case "shelf": Shelf.shared.add(args.dropFirst(3).map { URL(fileURLWithPath: $0) })
        case "quick": QuickActions.shared.show(files: args.dropFirst(3).map { URL(fileURLWithPath: $0) })
        case "presets": AppWindow.shared.show(.imagePresets)
        case "feel": AppWindow.shared.show(.feel)
        case "clothesline": AppWindow.shared.show(.clothesline)
        case "style": AppWindow.shared.show(.style)
        case "colors": AppWindow.shared.show(.colors)
        case "rename":
            if args.count > 3 { BatchRenameWindow(args.dropFirst(3).map { URL(fileURLWithPath: $0) }).show() }
            else { AppWindow.shared.show(.batchRename) }
        case "pdf":
            if args.count > 3 { PDFPagesWindow(args.dropFirst(3).map { URL(fileURLWithPath: $0) }).show() }
            else { AppWindow.shared.show(.pdfPages) }
        case "qr":
            if args.count > 3 { QRCodesWindow(args.dropFirst(3).map { URL(fileURLWithPath: $0) }).show() }
            else { AppWindow.shared.show(.qrCodes) }
        case "apps": AppWindow.shared.show(.appRouting)
        case "customize": AppWindow.shared.show(.customize)
        case "shortcuts": AppWindow.shared.show(.shortcuts)
        case "mywheel": CustomizePane.open(.custom)
        case "library": QRLibraryWindow().show()
        case "doctor":
            // SWIVEL_DOCTOR_SECTION=<summary|storage|caches|performance|…> opens that page (for checking it in a real window).
            let section = ProcessInfo.processInfo.environment["SWIVEL_DOCTOR_SECTION"].flatMap(DoctorSection.init(rawValue:))
            if args.count > 3 { DoctorWindow.present(app: URL(fileURLWithPath: args[3]), section: section) } else { DoctorWindow.present(section: section) }
            // SWIVEL_DOCTOR_RUN=1 also runs that page's check, as its Check button would.
            if let section, ProcessInfo.processInfo.environment["SWIVEL_DOCTOR_RUN"] == "1" { DoctorCenter.shared.run(section) }
            // SWIVEL_DOCTOR_PICK=<path> picks that folder (Folder Sizes, Duplicate Files, Project Builds) or app (Uninstall Apps).
            if let section, let pick = ProcessInfo.processInfo.environment["SWIVEL_DOCTOR_PICK"].map({ URL(fileURLWithPath: $0) }) {
                switch section {
                case .folders: DoctorCenter.shared.addFolder(pick)
                case .duplicates, .projects: DoctorCenter.shared.addFolders([pick], to: section)
                case .uninstall: DoctorCenter.shared.chooseUninstall(pick)
                default: break
                }
            }
        case "doctorsettings": AppWindow.shared.show(.doctor)
        case "launcher": Prefs.shortcutWheelEnabled = true; Prefs.isEnabled = true; ShortcutWheel.shared.sync(); ShortcutWheel.shared.show()
        default: AppWindow.shared.show()
        }
        app.run()
    }

    // `Swivel --feedback <check|play>`: check reports whether the trackpad actuator and the sounds are ready;
    // play runs through every haptic and sound once, a second apart.
    if args.count == 3, args[1] == "--feedback" {
        app.setActivationPolicy(.accessory)
        Feedback.prepare()
        if args[2] == "play" {
            let steps: [(String, () -> Void)] = [("hover", { Feedback.hover() }), ("page", { Feedback.page() }),
                                                 ("press", { Feedback.press() }), ("done", { Feedback.done() })]
            for (n, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(n)) { print(step.0); step.1() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (args[2] == "play" ? 5 : 0.6)) {
            print("actuator:", TrackpadActuator.isUsable ? "usable" : "unavailable", "devices:", TrackpadActuator.deviceCount,
                  "sounds:", Sounds.registeredCount)
            exit(0)
        }
        app.run()
    }

    // File-only OCR for smoke tests; does not touch the clipboard or launch screenshot watchers.
    if args.count == 3, args[1] == "--recognize" {
        Task { @MainActor in
            do { print(try await TextRecognition.recognize(URL(fileURLWithPath: args[2]))); exit(0) }
            catch { print("FAIL \(error.localizedDescription)"); exit(2) }
        }
        app.setActivationPolicy(.prohibited)
        app.run()
    }

    // `Swivel --run <convert|tools|actions> <item title> <file>...` runs one wheel item headlessly (for testing).
    if args.count >= 5, args[1] == "--run" {
        let mode: WheelMode = args[2] == "tools" ? .tools : args[2] == "actions" ? .actions : .convert
        let urls = args[4...].map { URL(fileURLWithPath: $0) }
        let items = Catalog.items(for: urls, mode: mode)
        guard let item = items.first(where: { $0.title.caseInsensitiveCompare(args[3]) == .orderedSame }) else {
            print("No item “\(args[3])”. Available: \(items.map(\.title).joined(separator: ", "))")
            exit(1)
        }
        Task { @MainActor in
            do {
                let result = try await item.run(urls)
                print("OK \(result.message)", result.files.map(\.path))
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription)")
                exit(2)
            }
        }
        app.setActivationPolicy(.prohibited)
        app.run()
    }

    // `Swivel --edit <crop|compress|edit|bg|blur|redact|metadata|annotate|collage|trim> <file>` opens one editor directly (for testing).
    if args.count >= 4, args[1] == "--edit" {
        let url = URL(fileURLWithPath: args[3])
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let editor: Editor = switch args[2] {
                case "compress": try CompressEditor(source: url)
                case "edit": try AdjustEditor(source: url)
                case "bg": try BackgroundEditor(source: url)
                case "blur": try BlurBackgroundEditor(source: url)
                case "retouch": try RetouchEditor(source: url)
                case "redact": try RedactEditor(source: url)
                case "metadata": try MetadataEditor(source: url)
                case "annotate": try AnnotateEditor(source: url)
                case "collage": try CollageEditor(urls: args[3...].map { URL(fileURLWithPath: $0) })
                case "idphoto": IDPhotoEditor(source: url)
                case "noise": NoiseReductionEditor(source: url)
                case "trim": try await TrimEditor(source: url)
                case "folder": try FolderStyleEditor(folders: args[3...].map { URL(fileURLWithPath: $0) })
                default: try CropEditor(source: url)
                }
                print("OK", try await editor.present().map(\.path))
            } catch {
                print("FAIL", error.localizedDescription)
            }
            exit(0)
        }
        app.run()
    }

    // `Swivel --frames <style> <out dir> [light|dark]` renders the menu's animations frame by frame to PNGs (for review):
    // open, a slow and a fast sweep across items, a page turn, then a drop.
    if args.count >= 4, args[1] == "--frames", let style = MenuStyle(rawValue: args[2]) {
        app.setActivationPolicy(.prohibited)
        if args.count >= 5 { app.appearance = NSAppearance(named: args[4] == "dark" ? .darkAqua : .aqua) }
        let titles = ["JPG", "PNG", "HEIC", "TIFF", "PDF", "GIF", "AVIF", "BMP"]
        let page1 = titles.map { WheelItem(title: $0) { _ in ActionResult(message: "") } }
        let page2 = ["WebP", "ICNS", "PSD"].map { WheelItem(title: $0) { _ in ActionResult(message: "") } }
        let size = WheelView.size(for: style, count: 8)
        let view = WheelView(frame: NSRect(origin: .zero, size: size))
        view.appearance = app.appearance
        view.style = style
        view.subtitle = "photo.heic"
        view.isLive = true
        view.manualClock = true
        view.configure(items: page1, mode: .convert, page: 0, pageCount: 2)
        let out = URL(fileURLWithPath: args[3])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let fps: CGFloat = 60
        // The pointer moves along a path like a real drag: out to the top sector, a slow arc clockwise, a fast flick
        // across three sectors, back to the hub (cancel), out again, a page turn, then a drop.
        let c = NSPoint(x: size.width / 2, y: size.height / 2)
        func at(_ degrees: CGFloat, _ r: CGFloat) -> NSPoint {
            NSPoint(x: c.x + cos(degrees * .pi / 180) * r, y: c.y + sin(degrees * .pi / 180) * r)
        }
        // For the wheel the pointer is driven by angle; other styles walk item to item.
        let wheel = style == .wheel
        var pointer: (CGFloat) -> NSPoint? = { _ in nil }
        if wheel {
            pointer = { t in
                switch t {
                case ..<0.3: return c
                case ..<0.45: return at(90, 20 + (t - 0.3) / 0.15 * 70)                // out to the top sector
                case ..<0.95: return at(90 - (t - 0.45) / 0.5 * 50, 90)                // slow clockwise arc
                case ..<1.05: return at(40 - (t - 0.95) / 0.1 * 140, 95)                // fast flick
                case ..<1.3: return at(-100, 95 - (t - 1.05) / 0.25 * 85)               // back into the hub
                case ..<1.5: return at(-100, 10)
                case ..<1.7: return at(-100 + 0, 10 + (t - 1.5) / 0.2 * 80)             // out again
                default: return at(-100, 90)
                }
            }
        }
        let script: [(CGFloat, () -> Void)] = wheel ? [
            (0, { view.beginOpen(pointer: c) }),
            (1.80, { view.configure(items: page2, mode: .convert, page: 1, pageCount: 2); view.track(at(-100, 90)) }),
            (2.25, { view.beginConfirm(view.hovered ?? 0) }),
        ] : [
            (0, { view.beginOpen() }),
            (0.40, { view.hovered = 0 }),
            (0.75, { view.hovered = 1 }),
            (0.85, { view.hovered = 2 }),
            (0.95, { view.hovered = 3 }),
            (1.40, { view.configure(items: page2, mode: .convert, page: 1, pageCount: 2) }),
            (1.85, { view.hovered = 1 }),
            (2.25, { view.beginConfirm(1) }),
        ]
        var drawTime: Double = 0, totalTime: Double = 0, timed = 0
        var next = 0
        for frame in 0..<Int(2.8 * fps) { autoreleasepool {
            let t = CGFloat(frame) / fps
            while next < script.count, script[next].0 <= t + 0.0001 { script[next].1(); next += 1 }
            if let p = pointer(t), t < 1.8 { view.track(p) }
            view.advance(1 / fps)
            let image = NSImage(size: size)
            image.lockFocus()
            NSGradient(colors: [NSColor(srgbRed: 0.47, green: 0.66, blue: 0.9, alpha: 1),
                                NSColor(srgbRed: 0.98, green: 0.8, blue: 0.62, alpha: 1)])!.draw(in: NSRect(origin: .zero, size: size), angle: -60)
            let scale = CGFloat(Double(ProcessInfo.processInfo.environment["SWIVEL_FRAMES_SCALE"] ?? "") ?? 1)
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = size
                let start = CACurrentMediaTime()
                view.cacheDisplay(in: view.bounds, to: rep)
                let took = CACurrentMediaTime() - start
                if frame > 2 { drawTime = max(drawTime, took); totalTime += took; timed += 1 }
                if ProcessInfo.processInfo.environment["SWIVEL_FRAMES_LOG"] != nil, took > 0.005 { print(String(format: "frame %d (t=%.2f) %.2f ms", frame, Double(t), took * 1000)) }
                rep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: false, hints: nil)
            }
            image.unlockFocus()
            if let p = pointer(t), t < 1.8 {
                // Mark the pointer.
                image.lockFocus()
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
                image.unlockFocus()
            }
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: out.appendingPathComponent(String(format: "f%03d_%.3f.png", frame, Double(t))))
            }
        } }
        print(String(format: "OK draw: mean %.2f ms, slowest %.2f ms", totalTime / Double(max(timed, 1)) * 1000, drawTime * 1000))
        exit(0)
    }

    // `Swivel --demo <mode> <file> [script] [style]` shows the menu at the pointer without a drag (for screenshots and
    // recordings). The script is one hover index ("2"), or steps run every 0.35 s: "0,1,2,n,1,p1" (n = next page,
    // p = drop on that item). The style applies to this run only; the saved setting is left alone.
    if args.count >= 4, args[1] == "--demo" {
        let mode: WheelMode = args[2] == "tools" ? .tools : args[2] == "actions" ? .actions : .convert
        let style = args.count >= 6 ? MenuStyle(rawValue: args[5]) : nil
        let controller = WheelController()
        controller.styleOverride = style
        controller.keyTapped(mode, urls: [URL(fileURLWithPath: args[3])])
        let steps = args.count >= 5 ? args[4].split(separator: ",").map(String.init) : []
        var lastStep = 0.0
        for (n, step) in steps.enumerated() {
            let at = steps.count == 1 ? 0 : 0.6 + Double(n) * 0.35
            lastStep = at
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                if step == "n" { controller.demoNextPage() }
                else if step.hasPrefix("p"), let i = Int(step.dropFirst()) { controller.demoPress(i) }
                else if let i = Int(step) { controller.demoHover(i) }
            }
        }
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(6, lastStep + 1.5)) { exit(0) }
        app.run()
    }

    do { if try AppInstance.reopenExisting() { exit(0) } }
    catch { NSAlert(error: error).runModal(); exit(1) }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
