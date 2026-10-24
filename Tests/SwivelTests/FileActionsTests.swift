import AppKit
import Carbon
import CoreImage
import ImageIO
import PDFKit
import Testing
@testable import Swivel

@Suite(.serialized)
@MainActor
struct FileActionsTests {
    @Test func importingAnImageWithoutCodesKeepsTheEmptyResultMessageAndNoUndoStep() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults.standard, before = defaults.object(forKey: "feature.qrCodes")
        defer { if let before { defaults.set(before, forKey: "feature.qrCodes") } else { defaults.removeObject(forKey: "feature.qrCodes") } }
        defaults.set(true, forKey: "feature.qrCodes")
        let image = dir.appendingPathComponent("blank.png")
        try png(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 300)), image)
        let store = QRLibraryStore(directory: dir.appendingPathComponent("library")), library = QRLibraryWindow(store: store)
        library.ingestImages([image])
        for _ in 0..<500 where library.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!library.isBusy)
        #expect(try store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(library.window.contentView!)
        #expect(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == L("No readable QR codes or barcodes found.") })
        #expect(views.compactMap { $0 as? NSButton }.contains { $0.title == L("Undo") && !$0.isEnabled })
    }

    @Test func appCustomizationIncludesEveryAllowedExtensionInItsCategory() {
        let defaults = UserDefaults.standard, keys = ["feature.appRouting"] + Prefs.fileAppTargetKeys
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set(true, forKey: "feature.appRouting")
        let text = FileAppTarget(id: "text-only", name: "Text", bundleID: "", appPath: "", delivery: .openFiles, extensions: ["txt"])
        let image = FileAppTarget(id: "png-only", name: "PNG", bundleID: "", appPath: "", delivery: .openFiles, extensions: ["png"])
        Prefs.fileAppTargets = [text, image]
        #expect(Catalog.allItems(mode: .apps, kind: .document) == [text.actionID])
        #expect(Catalog.allItems(mode: .apps, kind: .image) == [image.actionID])
        #expect(Catalog.allItems(mode: .apps, kind: .pdf).isEmpty)
        #expect(Catalog.defaultItems(for: [URL(fileURLWithPath: "/fixture.jpg")], mode: .apps).isEmpty)
        #expect(Catalog.defaultItems(for: [URL(fileURLWithPath: "/fixture.txt")], mode: .apps).map(\.title) == [text.actionID])
    }

    @Test func symbolicSystemShortcutsBlockOnlyEnabledMatchingCombinations() {
        let modifiers = UInt32(controlKey | optionKey)
        let keys = [SystemShortcuts.Key(code: 49, modifiers: modifiers, enabled: true),
                    SystemShortcuts.Key(code: 38, modifiers: modifiers, enabled: false)]
        #expect(SystemShortcuts.contains(code: WheelShortcut.space.keyCode, modifiers: modifiers, in: keys))
        #expect(!SystemShortcuts.contains(code: WheelShortcut.j.keyCode, modifiers: modifiers, in: keys))
        #expect(!SystemShortcuts.contains(code: 49, modifiers: UInt32(controlKey), in: keys))
    }

    @Test func toolWheelShortcutDefaultsToJAndRequiresTheWholeCombination() {
        let defaults = UserDefaults.standard, before = defaults.object(forKey: "wheel.shortcut")
        defer { if let before { defaults.set(before, forKey: "wheel.shortcut") } else { defaults.removeObject(forKey: "wheel.shortcut") } }
        defaults.removeObject(forKey: "wheel.shortcut")
        #expect(Prefs.wheelShortcut == .j)
        func event(_ flags: NSEvent.ModifierFlags, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: repeatKey, keyCode: 38)!
        }
        #expect(WheelShortcut.j.matches(event([.control, .option])))
        #expect(!WheelShortcut.j.matches(event([])))
        #expect(!WheelShortcut.j.matches(event([.control, .option, .command])))
        #expect(!WheelShortcut.j.matches(event([.control, .option], repeatKey: true)))
        #expect(!WheelShortcut.space.matches(event([.control, .option])))
    }

    @Test func emptyLibraryShowsCreationActionsAndRevealsSavedTrees() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults.standard, before = defaults.object(forKey: "feature.qrCodes")
        defer { if let before { defaults.set(before, forKey: "feature.qrCodes") } else { defaults.removeObject(forKey: "feature.qrCodes") } }
        defaults.set(true, forKey: "feature.qrCodes")
        let store = QRLibraryStore(directory: dir), library = QRLibraryWindow(store: store)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(library.window.contentView!)
        #expect(library.tree.isHidden)
        #expect(views.compactMap { $0 as? NSButton }.filter { $0.title == L("New Code…") && $0.isEnabled }.count == 2)
        #expect(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == L("Save your first QR code") })
        try store.add(SavedQRCode(name: "Saved", value: "https://example.com"))
        #expect(!library.tree.isHidden)
        try store.save([])
        #expect(library.tree.isHidden)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwivelActions-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    @discardableResult private func file(_ directory: URL, _ name: String, _ value: String = "original") throws -> URL {
        let url = directory.appendingPathComponent(name); try Data(value.utf8).write(to: url); return url
    }
    private func content(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func pdf(_ url: URL, labels: [String]) throws {
        let document = PDFDocument()
        for (index, label) in labels.enumerated() {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 300 + index * 10, height: 400)
            let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (label as NSString).draw(at: NSPoint(x: 30, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF()
            document.insert(PDFDocument(data: data as Data)!.page(at: 0)!, at: document.pageCount)
        }
        #expect(document.write(to: url))
    }
    private func qr(_ value: String) -> CIImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(value.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        return filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    }
    private func png(_ image: CIImage, _ url: URL) throws {
        let cg = CIContext().createCGImage(image, from: image.extent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil); #expect(CGImageDestinationFinalize(dest))
    }

    @Test func renameCombinesRulesAndKeepsExtensionsAndFolderNames() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try file(dir, "照片-raw.PNG")
        let rules = RenameRules(find: "raw", replacement: "final", prefix: "项目-", suffix: "-好", number: true, start: 7, digits: 3)
        #expect(rules.name(for: photo, index: 0) == "项目-照片-final-好-007.PNG")
        let sub = dir.appendingPathComponent("project.assets"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        #expect(RenameRules(prefix: "new-").name(for: sub, index: 0) == "new-project.assets")
        #expect(RenameRules(base: "item", number: true, start: 9, digits: 2).name(for: photo, index: 1) == "item-10.PNG")
    }

    @Test func renamePreviewFindsDuplicateNamesExternalConflictsAndInvalidNames() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try file(dir, "a.txt"), b = try file(dir, "b.txt")
        #expect(!RenamePlan.preview([a, b], rules: RenameRules(base: "same")).canApply)
        _ = try file(dir, "new-a.txt", "keep")
        #expect(!RenamePlan.preview([a], rules: RenameRules(prefix: "new-")).canApply)
        for bad in ["", ".", "..", ".hidden", "a/b", "a:b", "a\0b", "a\nb", String(repeating: "长", count: 100)] {
            #expect(!RenamePlan.validName(bad))
        }
        #expect(!RenamePlan.preview([a], rules: RenameRules(number: true, start: -1)).canApply)
        #expect(RenamePlan.preview([a, a], rules: RenameRules(prefix: "x-")).entries.count == 1)
        #expect(!RenamePlan.preview([a], rules: RenameRules()).canApply)
    }

    @Test func renameRejectsMissingAndParentChildSelections() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try file(dir, "a")
        #expect(!RenamePlan.preview([dir, a], rules: RenameRules(prefix: "x")).canApply)
        #expect(!RenamePlan.preview([dir.appendingPathComponent("missing")], rules: RenameRules(prefix: "x")).canApply)
    }

    @Test func renameAndUndoPreserveDataAcrossDirectories() throws {
        let aDir = try folder(), bDir = try folder()
        defer { try? FileManager.default.removeItem(at: aDir); try? FileManager.default.removeItem(at: bDir) }
        let a = try file(aDir, "one.txt", "alpha"), b = try file(bDir, "two.txt", "beta")
        let plan = RenamePlan.preview([a, b], rules: RenameRules(base: "invoice", number: true))
        let receipt = try BatchRenamer.execute(plan)
        #expect(try content(plan.entries[0].destination) == "alpha")
        #expect(try content(plan.entries[1].destination) == "beta")
        _ = try receipt.undo()
        #expect(try content(a) == "alpha"); #expect(try content(b) == "beta")
        #expect(try FileManager.default.contentsOfDirectory(atPath: aDir.path) == ["one.txt"])
    }

    @Test func renameSupportsSwapsAndCaseOnlyChanges() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try file(dir, "Alpha.txt", "alpha"), b = try file(dir, "Beta.txt", "beta")
        let rows = [RenameEntry(source: a, destination: b, identity: try FileIdentity.read(a)),
                    RenameEntry(source: b, destination: a, identity: try FileIdentity.read(b))]
        let receipt = try BatchRenamer.execute(RenamePlan.validate(rows))
        #expect(try content(a) == "beta"); #expect(try content(b) == "alpha")
        _ = try receipt.undo()
        let plan = RenamePlan.preview([a], rules: RenameRules(find: "Alpha", replacement: "alpha"))
        #expect(plan.canApply)
        _ = try BatchRenamer.execute(plan)
        #expect(try content(dir.appendingPathComponent("alpha.txt")) == "alpha")
    }

    @Test func staleRenamePreviewAndLateDestinationCannotReplaceFiles() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try file(dir, "a.txt", "old")
        let plan = RenamePlan.preview([a], rules: RenameRules(prefix: "new-"))
        try FileManager.default.moveItem(at: a, to: dir.appendingPathComponent("saved-old"))
        try Data("replacement".utf8).write(to: a)
        #expect(throws: (any Error).self) { try BatchRenamer.execute(plan) }
        #expect(try content(a) == "replacement")
        let fresh = RenamePlan.preview([a], rules: RenameRules(prefix: "new-"))
        _ = try file(dir, "new-a.txt", "blocker")
        #expect(throws: (any Error).self) { try BatchRenamer.execute(fresh) }
        #expect(try content(a) == "replacement"); #expect(try content(dir.appendingPathComponent("new-a.txt")) == "blocker")
    }

    @Test func renameRollsBackFailuresInStagingAndCommit() throws {
        for failAt in [2, 4] {
            let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
            let a = try file(dir, "a.txt", "alpha"), b = try file(dir, "b.txt", "beta")
            let plan = RenamePlan.preview([a, b], rules: RenameRules(prefix: "new-"))
            var calls = 0
            #expect(throws: (any Error).self) {
                try BatchRenamer.execute(plan) { from, to in
                    calls += 1
                    if calls == failAt { throw ToolError("injected failure") }
                    try BatchRenamer.move(from, to)
                }
            }
            #expect(try content(a) == "alpha"); #expect(try content(b) == "beta")
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["a.txt", "b.txt"])
        }
    }

    @Test func renameNoReplaceIsAtomicAndUndoRejectsConflicts() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try file(dir, "a.txt", "alpha"), b = try file(dir, "b.txt", "beta")
        #expect(throws: (any Error).self) { try BatchRenamer.move(a, b) }
        #expect(try content(a) == "alpha"); #expect(try content(b) == "beta")
        let receipt = try BatchRenamer.execute(RenamePlan.preview([a], rules: RenameRules(prefix: "new-")))
        _ = try file(dir, "a.txt", "new-original")
        #expect(throws: (any Error).self) { try receipt.undo() }
        #expect(try content(a) == "new-original"); #expect(try content(receipt.entries[0].destination) == "alpha")
    }

    @Test func renameWorksOnExFATAndStillNeverReplacesALateFile() throws {
        // exFAT has no RENAME_EXCL (ENOTSUP), so every rename there used to fail.
        let volume = try ScratchVolume.exFAT()
        defer { volume.detach() }
        let fm = FileManager.default
        let dir = volume.root.appendingPathComponent("Photos", isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Album"), withIntermediateDirectories: true)
        let a = try file(dir, "a.txt", "alpha"), b = try file(dir, "b.txt", "beta"), album = dir.appendingPathComponent("Album")
        try file(album, "inside.txt", "inside")
        func names() throws -> Set<String> { Set(try fm.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix("._") }) }

        let receipt = try BatchRenamer.execute(RenamePlan.preview([a, b, album], rules: RenameRules(prefix: "new-")))
        #expect(try names() == ["new-a.txt", "new-b.txt", "new-Album"])
        #expect(try content(dir.appendingPathComponent("new-a.txt")) == "alpha")
        #expect(try content(dir.appendingPathComponent("new-Album/inside.txt")) == "inside")
        _ = try receipt.undo()
        #expect(try names() == ["a.txt", "b.txt", "Album"])

        // A case-only change on a case-insensitive volume.
        _ = try BatchRenamer.execute(RenamePlan.preview([a], rules: RenameRules(find: "a", replacement: "A")))
        #expect(try names() == ["A.txt", "b.txt", "Album"])
        let upper = dir.appendingPathComponent("A.txt")

        // A file saved under a new name after the preview stays, and the batch rolls back.
        let plan = RenamePlan.preview([upper, b], rules: RenameRules(prefix: "new-"))
        #expect(throws: (any Error).self) {
            try BatchRenamer.execute(plan) { from, to in
                if to.lastPathComponent == "new-b.txt", !fm.fileExists(atPath: to.path) { try Data("late".utf8).write(to: to) }
                try BatchRenamer.move(from, to)
            }
        }
        #expect(try content(dir.appendingPathComponent("new-b.txt")) == "late")
        #expect(try content(upper) == "alpha"); #expect(try content(b) == "beta")
        #expect(try names() == ["A.txt", "b.txt", "Album", "new-b.txt"])
    }

    @Test func renameReportsRecoveryLocationsWithoutOverwritingANewOriginal() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try file(dir, "a.txt", "alpha"), b = try file(dir, "b.txt", "beta")
        let plan = RenamePlan.preview([a, b], rules: RenameRules(prefix: "new-"))
        var calls = 0
        do {
            _ = try BatchRenamer.execute(plan) { from, to in
                calls += 1
                if calls == 3 { try Data("blocker".utf8).write(to: a); throw ToolError("injected failure") }
                try BatchRenamer.move(from, to)
            }
            Issue.record("Rename must fail")
        } catch { #expect(error.localizedDescription.contains(".swivel-rename-")) }
        #expect(try content(a) == "blocker"); #expect(try content(b) == "beta")
        let staged = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".swivel-rename-") }
        #expect(staged.count == 1); #expect(try content(staged[0]) == "alpha")
    }

    @Test func pdfRangeValidationAndPageMovement() throws {
        #expect(try PDFPageOrder.parse("1, 3-5，3", count: 6) == IndexSet([0, 2, 3, 4]))
        for invalid in ["", "0", "7", "5-3", "1,", "x", "1--2", "1-99999999999"] {
            #expect(throws: (any Error).self) { try PDFPageOrder.parse(invalid, count: 6) }
        }
        let pages = (0..<5).map { PDFPageItem(source: URL(fileURLWithPath: "/tmp/a.pdf"), page: $0) }
        #expect(PDFPageOrder.moving(pages, indexes: [1, 2], to: 5).map(\.page) == [0, 3, 4, 1, 2])
        #expect(PDFPageOrder.moving(pages, indexes: [3, 4], to: 0).map(\.page) == [3, 4, 0, 1, 2])
        #expect(PDFPageOrder.moving(pages, indexes: [1, 2], to: 2) == pages)
    }

    @Test func pdfExportsExactOrderRotationSelectionAndUniqueFiles() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.pdf"); try pdf(source, labels: ["PAGE A", "PAGE B", "PAGE C"])
        let original = try Data(contentsOf: source), snapshot = try PDFPagesSnapshot.load([source])
        var rotated = snapshot.items[2]; rotated.rotation = 90
        let output = try snapshot.export([rotated, snapshot.items[0]])
        let second = try snapshot.export([snapshot.items[1]])
        let read = PDFDocument(url: output)!
        #expect(read.pageCount == 2); #expect(read.page(at: 0)?.string?.contains("PAGE C") == true)
        #expect(read.page(at: 1)?.string?.contains("PAGE A") == true); #expect(read.page(at: 0)?.rotation == 90)
        #expect(PDFDocument(url: second)?.pageCount == 1); #expect(output != second)
        #expect(try Data(contentsOf: source) == original)
        #expect(output.deletingLastPathComponent() == dir)
        #expect(throws: (any Error).self) { try snapshot.export([]) }
    }

    @Test func pdfSnapshotsSurviveExternalEditsAndCombineDifferentSources() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf")
        try pdf(a, labels: ["ALPHA"]); try pdf(b, labels: ["BETA"])
        let snapshot = try PDFPagesSnapshot.load([a, b])
        try Data("changed".utf8).write(to: a)
        let output = try snapshot.export(snapshot.items.reversed())
        let result = PDFDocument(url: output)!
        #expect(result.page(at: 0)?.string?.contains("BETA") == true)
        #expect(result.page(at: 1)?.string?.contains("ALPHA") == true)
        #expect(throws: (any Error).self) { try PDFPagesSnapshot.load([a]) }
        #expect(throws: (any Error).self) { try PDFPagesSnapshot.load([]) }
    }

    @Test func qrRecognitionReadsTextAndRotatedUnicodeURLs() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("qr.png")
        let payload = "https://example.com/你好?q=a%26b"
        let code = qr(payload)
        let rotated = code.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
        try png(rotated, source)
        let original = try Data(contentsOf: source)
        let results = try await CodeRecognition.recognize([source])
        #expect(results.count == 1); #expect(results.first?.value == payload); #expect(results.first?.webURL != nil)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func qrFindsMultipleCodesAndDoesNotTreatTextAsAWebLink() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("multiple.png")
        let left = qr("SWIVEL TEST"), right = qr("https://example.com/path")
        let width = max(left.extent.width, right.extent.width) + 100
        let canvas = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width * 2, height: width))
        let image = left.transformed(by: .init(translationX: 30, y: 30)).composited(over: right.transformed(by: .init(translationX: width + 30, y: 30)).composited(over: canvas))
        try png(image, source)
        let results = try await CodeRecognition.recognize([source])
        #expect(Set(results.map(\.value)) == ["SWIVEL TEST", "https://example.com/path"])
        #expect(results.first { $0.value == "SWIVEL TEST" }?.webURL == nil)
    }

    @Test func qrBlankAndBrokenImagesAndLinkSchemeChecks() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let blank = dir.appendingPathComponent("blank.png")
        try png(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 300)), blank)
        #expect(try await CodeRecognition.recognize([blank]).isEmpty)
        let bad = try file(dir, "broken.png")
        await #expect(throws: (any Error).self) { try await CodeRecognition.recognize([bad]) }
        for value in ["javascript:alert(1)", "file:///etc/passwd", "claude://code/new", "https://user:secret@example.com", "just text"] {
            #expect(DetectedCode(source: blank, kind: "QR", value: value).webURL == nil)
        }
    }

    @Test func assistantDraftsEncodePathsAndNeverSendOrPretendToAttach() throws {
        let files = [URL(fileURLWithPath: "/tmp/资料 A/#&?\".txt"), URL(fileURLWithPath: "/tmp/资料 A/b.txt")]
        for delivery in [FileAppTarget.Delivery.codexDraft, .claudeCodeDraft] {
            let link = try AssistantDraft.url(for: delivery, files: files)
            let c = URLComponents(url: link, resolvingAgainstBaseURL: false)!
            #expect(c.path == "/new")
            let parameters = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value!) })
            #expect(parameters[delivery == .codexDraft ? "prompt" : "q"] == AssistantDraft.referenceText(files))
            #expect(parameters[delivery == .codexDraft ? "path" : "folder"] == "/tmp/资料 A")
            #expect(parameters["file"] == nil && parameters["submit"] == nil && parameters["send"] == nil)
        }
        let mixed = try AssistantDraft.url(for: .codexDraft, files: [files[0], URL(fileURLWithPath: "/elsewhere/b.txt")])
        #expect(URLComponents(url: mixed, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "path" } == false)
        #expect(throws: (any Error).self) { try AssistantDraft.url(for: .codexDraft, files: []) }
    }

    @Test func appFiltersPersistenceAndStableNames() throws {
        let defaults = UserDefaults.standard, keys = Prefs.fileAppTargetKeys
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        var target = FileAppTarget.starters[0]
        let id = target.actionID; target.name = "My Codex"; target.extensions = FileAppTarget.normalizedExtensions(".PNG, jpg，PNG pdf")
        #expect(target.actionID == id); #expect(target.extensions == ["png", "jpg", "pdf"])
        #expect(target.accepts([URL(fileURLWithPath: "/tmp/A.PNG")]))
        #expect(!target.accepts([URL(fileURLWithPath: "/tmp/A.PNG"), URL(fileURLWithPath: "/tmp/a.txt")]))
        Prefs.fileAppTargets = [target, target]
        #expect(Prefs.fileAppTargets == [target]); #expect(Catalog.displayTitle(id) == "My Codex")
        #expect(try JSONDecoder().decode(FileAppTarget.self, from: JSONEncoder().encode(target)) == target)
    }

    @Test func independentFeatureGatesIncludeWheelOffAndStaleActions() async throws {
        let defaults = UserDefaults.standard
        let features: [Feature] = [.batchRename, .pdfPages, .qrCodes, .appRouting]
        let keys = ["enabled"] + Prefs.fileAppTargetKeys + features.map { "feature." + $0.rawValue }
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let image = [URL(fileURLWithPath: "/tmp/a.png")], pdf = [URL(fileURLWithPath: "/tmp/a.pdf")]
        for f in features { Prefs.setFeatureEnabled(f, false) }
        #expect(!Catalog.defaultItems(for: image, mode: .actions).contains { $0.title == "Batch Rename" || $0.title.hasPrefix("app.") })
        #expect(!Catalog.defaultItems(for: image, mode: .tools).contains { $0.title == "Read QR Codes" })
        #expect(!Catalog.defaultItems(for: pdf, mode: .tools).contains { $0.title == "Arrange PDF Pages" })
        Prefs.isEnabled = false
        for f in features { Prefs.setFeatureEnabled(f, true) }
        Prefs.fileAppTargets = FileAppTarget.starters
        #expect(QuickActions.makeCommands(files: image).contains { $0.id == "actions.Batch Rename" })
        #expect(QuickActions.makeCommands(files: image).contains { $0.id == "tools.Read QR Codes" })
        #expect(QuickActions.makeCommands(files: pdf).contains { $0.id == "tools.Arrange PDF Pages" })
        #expect(QuickActions.makeCommands(files: image).contains { $0.id == "apps.app.codex" })
        #expect(QuickActions.makeCommands(files: []).contains { $0.id == "choose.batchRename" })
        let oldAction = Catalog.defaultItems(for: image, mode: .tools).first { $0.title == "Read QR Codes" }!
        Prefs.setFeatureEnabled(.qrCodes, false)
        await #expect(throws: (any Error).self) { try await oldAction.run(image) }
        #expect(Feature.batchRename.isOn && Feature.pdfPages.isOn && Feature.appRouting.isOn)
    }
}

extension FileActionsTests {
    @Test func qrLibraryPersistsAcrossRestartsAndDeduplicatesWithoutNeedingOriginals() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = QRLibraryStore(directory: dir)
        let first = SavedQRCode(name: "Website", value: "https://example.com", collection: "Work", season: .autumn)
        #expect(try store.load().isEmpty)
        let saved = try store.add(first)
        let same = try store.add(SavedQRCode(name: "Duplicate", value: first.value, collection: "Work"))
        #expect(saved.id == same.id)
        let reloaded = try QRLibraryStore(directory: dir).load()
        #expect(reloaded == [first]); #expect(reloaded[0].season == .autumn)
        #expect((try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func qrLibraryUndoPreservesOtherWindowsChangesAndRefusesConflictingEdits() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = QRLibraryStore(directory: dir)
        let a = SavedQRCode(name: "A", value: "alpha"), b = SavedQRCode(name: "B", value: "beta")
        try store.save([a]); try store.save([]) // A deleted in one window.
        _ = try store.add(b) // B added by a second window.
        try store.revert(before: [a], after: [])
        #expect(Set(try store.load().map(\.id)) == [a.id, b.id])
        var changed = a; changed.name = "Edited elsewhere"
        try store.save([changed, b])
        #expect(throws: (any Error).self) { try store.revert(before: [], after: [a]) }
        #expect(try store.load().contains(changed))
    }

    @Test func qrLibraryInvalidAndCorruptedDataIsNeverSilentlyOverwritten() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = QRLibraryStore(directory: dir)
        let a = SavedQRCode(name: "Keep", value: "https://example.com")
        try store.save([a]); let before = try Data(contentsOf: store.file)
        #expect(throws: (any Error).self) { try store.save([SavedQRCode(name: "", value: "")]) }
        #expect(try Data(contentsOf: store.file) == before)
        try Data("broken data".utf8).write(to: store.file)
        #expect(throws: (any Error).self) { try store.add(a) }
        #expect(try String(contentsOf: store.file, encoding: .utf8) == "broken data")
    }

    @Test func generatedLibraryQRImagesRoundTripUnicodeAndKeepContentForEverySeason() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        for season in QRSeason.allCases {
            let value = SavedQRCode(name: "树", value: "https://example.com/资料?a=1&b=two#hello", season: season)
            let output = dir.appendingPathComponent(season.rawValue + ".png")
            try QRImage.png(value.value).write(to: output)
            let recognized = try await CodeRecognition.recognize([output])
            #expect(recognized.map(\.value) == [value.value])
        }
        #expect(throws: (any Error).self) { try QRImage.png("") }
        #expect(throws: (any Error).self) { try QRImage.png(String(repeating: "a", count: 2001)) }
        #expect(QRGardenView.seed("same") == QRGardenView.seed("same"))
        #expect(QRGardenView.seed("same") != QRGardenView.seed("different"))
    }

    @Test func nativeAppRoutingUsesExplicitFilesAndPrivateClipboardAndHandlesFailures() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: fake.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "local.swivel.routing-fixture", "CFBundlePackageType": "APPL", "CFBundleName": "Fixture", "CFBundleURLTypes": [["CFBundleURLSchemes": ["codex", "claude"]]]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: fake.appendingPathComponent("Contents/Info.plist"))
        let source = try file(dir, "file & #.txt")
        let keys = ["feature.appRouting"] + Prefs.fileAppTargetKeys, defaults = UserDefaults.standard
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        Prefs.setFeatureEnabled(.appRouting, true)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        pasteboard.setString("keep clipboard", forType: .string)
        var target = FileAppTarget(id: "fixture", name: "Fixture", bundleID: "local.swivel.routing-fixture", appPath: fake.path, delivery: .openFiles)
        Prefs.fileAppTargets = [target]
        var calls = 0
        _ = try await FileAppRouting.run(target, files: [source], pasteboard: pasteboard) { urls, app in
            #expect(urls == [source]); #expect(app == fake); calls += 1
        }
        #expect(calls == 1); #expect(pasteboard.string(forType: .string) == "keep clipboard")
        target.delivery = .copyFiles; Prefs.fileAppTargets = [target]
        await #expect(throws: (any Error).self) {
            try await FileAppRouting.run(target, files: [source], pasteboard: pasteboard) { _, _ in throw ToolError("open failed") }
        }
        #expect(pasteboard.string(forType: .string) == "keep clipboard")
        _ = try await FileAppRouting.run(target, files: [source], pasteboard: pasteboard) { urls, _ in #expect(urls.isEmpty) }
        #expect(ToolUI.fileURLs(from: pasteboard) == [source])
        target.delivery = .codexDraft; Prefs.fileAppTargets = [target]
        _ = try await FileAppRouting.run(target, files: [source], pasteboard: pasteboard) { urls, _ in
            #expect(urls.count == 1 && urls[0].scheme == "codex")
        }
        var edited = target; edited.name = "Edited"; Prefs.fileAppTargets = [edited]
        await #expect(throws: (any Error).self) {
            try await FileAppRouting.run(target, files: [source], pasteboard: pasteboard) { _, _ in Issue.record("A stale action must not open an app") }
        }
    }

    @Test func wheelKeyMigrationKeepsCustomKeysAndAssignsUniqueNewKeys() {
        let defaults = UserDefaults.standard, keys = WheelMode.allCases.map { "key." + $0.id }
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        keys.forEach(defaults.removeObject(forKey:))
        defaults.set("option", forKey: "key.convert"); defaults.set("fn", forKey: "key.tools")
        #expect(Prefs.key(for: .convert) == .option && Prefs.key(for: .tools) == .fn)
        // Five keys for the five built-in menus; My Wheel gets none until the user gives it one.
        let builtIn = WheelMode.allCases.filter { $0 != .custom }
        #expect(Set(builtIn.map { Prefs.key(for: $0) }).count == 5 && !builtIn.contains { Prefs.key(for: $0) == .off })
        #expect(Prefs.key(for: .custom) == .off)
        Prefs.setKey(.option, for: .apps)
        #expect(Prefs.key(for: .apps) == .option)
        #expect(Set(builtIn.map { Prefs.key(for: $0) }).count == 5)
    }

    @Test func clickableWheelKeyboardSelectsAndCancelsWithoutADrag() {
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: 340, height: 340))
        view.isClickable = true
        view.configure(items: [WheelItem(title: "A") { _ in ActionResult(message: "") }, WheelItem(title: "B") { _ in ActionResult(message: "") }], mode: .tools, page: 0, pageCount: 2)
        var chosen: String?, cancelled = false, paged = false
        view.onClick = { chosen = $0.title }; view.onCancel = { cancelled = true }; view.onNextPage = { paged = true }
        func key(_ code: UInt16) -> NSEvent { NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)! }
        view.keyDown(with: key(125)); #expect(view.hovered == 0)
        view.keyDown(with: key(124)); #expect(view.hovered == 1)
        view.keyDown(with: key(36)); #expect(chosen == "B")
        view.keyDown(with: key(53)); #expect(cancelled)
        view.keyDown(with: key(49)); #expect(paged)
    }

    @Test func newWheelsRespectFeatureSwitchesAndStandaloneLaunchers() {
        let defaults = UserDefaults.standard
        let features: [Feature] = [.batchRename, .pdfPages, .qrCodes, .appRouting]
        let keys = features.map { "feature." + $0.rawValue }
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        features.forEach { Prefs.setFeatureEnabled($0, false) }
        #expect(Catalog.items(for: [], mode: .apps).isEmpty && Catalog.items(for: [], mode: .codes).isEmpty)
        #expect(ShortcutWheel.shared.items().map(\.title) == ["Open Swivel…"])
        features.forEach { Prefs.setFeatureEnabled($0, true) }
        #expect(Catalog.items(for: [], mode: .codes).first?.title == "QR Library")
        #expect(!Catalog.items(for: [], mode: .apps).isEmpty)
        #expect(Set(ShortcutWheel.shared.items().map(\.title)).isSuperset(of: ["Batch Rename", "Arrange PDF Pages", "Read QR Codes", "QR Library", "App Actions"]))
    }

    @Test func prepareFileActionPreviewFixtures() throws {
        guard let path = ProcessInfo.processInfo.environment["SWIVEL_FILE_ACTIONS_FIXTURES"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try file(directory, "photo-one.txt", "first fixture"); _ = try file(directory, "photo-two.txt", "second fixture")
        try pdf(directory.appendingPathComponent("pages.pdf"), labels: ["PAGE ONE", "PAGE TWO", "PAGE THREE", "PAGE FOUR"])
        try QRImage.png("https://example.com/swivel-test").write(to: directory.appendingPathComponent("code.png"))
        let library = QRLibraryStore(directory: directory.appendingPathComponent("library"))
        try library.save([SavedQRCode(name: "Swivel", value: "https://example.com/swivel", collection: "Work"), SavedQRCode(name: "Notes", value: "Local test note", collection: "Personal", season: .spring)])
    }
}

extension FileActionsTests {
    @Test func librariesSavedBeforeTemplatesStillLoad() throws {
        let json = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","name":"Old","value":"https://example.com","collection":"","season":"spring","created":700000000}]"#
        let values = try JSONDecoder().decode([SavedQRCode].self, from: Data(json.utf8))
        #expect(values.count == 1); #expect(values[0].template == .tree); #expect(values[0].season == .spring)
        var bouquet = values[0]; bouquet.template = .island
        #expect(try JSONDecoder().decode(SavedQRCode.self, from: JSONEncoder().encode(bouquet)) == bouquet)
    }

    /// Seen from straight above, every template shows exactly the code: dark modules covered by dark surfaces,
    /// light modules by light ones, with clear contrast between them.
    @Test func everyTemplateTopSurfaceMatchesTheCode() throws {
        func luminance(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        let dark = try QRModules.matrix("https://example.com/swivel")
        #expect(dark.count == 25); #expect(dark[0][0] && dark[0][6] && !dark[1][1])
        for template in QRTemplate.allCases { for season in QRSeason.allCases {
            let model = QRGardenModel.build(dark, template: template, season: season, seed: 42)
            var darkest: Float = 0, lightest: Float = 1
            for r in 0..<model.size { for c in 0..<model.size {
                let l = luminance(model.topColor(row: r, column: c) ?? SIMD3(0.93, 0.93, 0.93))
                if dark[r][c] { darkest = max(darkest, l) } else { lightest = min(lightest, l) }
            } }
            #expect(lightest - darkest > 0.12, "\(template) \(season): dark ≤ \(darkest), light ≥ \(lightest)")
        } }
    }

    @Test func renderScenesAndCheckTheyScanFromAbove() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIVEL_FILE_ACTIONS_RENDERS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = QRGardenView(frame: NSRect(x: 0, y: 0, width: 620, height: 520))
        for template in QRTemplate.allCases { for season in QRSeason.allCases {
            let value = SavedQRCode(name: "Swivel", value: "https://example.com/swivel", season: season, template: template)
            try view.display(value)
            for showCode in [false, true] {
                let picture = view.snapshot(size: CGSize(width: 900, height: 760), showsCode: showCode)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 760, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor(white: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 900, height: 760).fill()
                picture.draw(in: NSRect(x: 0, y: 0, width: 900, height: 760)); NSGraphicsContext.restoreGraphicsState()
                let output = directory.appendingPathComponent("\(template.rawValue)-\(season.rawValue)-\(showCode ? "qr" : "scene").png")
                try rep.representation(using: .png, properties: [:])!.write(to: output)
                if showCode {
                    let recognized = try await CodeRecognition.recognize([output])
                    #expect(recognized.map(\.value) == [value.value], "\(template) \(season) does not scan")
                }
            }
        } }
    }
}

extension FileActionsTests {
    /// Renders a transition filmstrip and times the work per frame for the largest code.
    @Test func renderTransitionFilmstripWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["SWIVEL_QR_FILMSTRIP"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = QRGardenView(frame: NSRect(x: 0, y: 0, width: 620, height: 520))
        for (name, value) in [("short", "https://example.com/swivel"), ("long", String(repeating: "https://example.com/a-long-path?", count: 30))] {
            var built = Date()
            try view.display(SavedQRCode(name: name, value: value, template: .tree))
            print("\(name): build \(Int(Date().timeIntervalSince(built) * 1000)) ms")
            built = Date()
            for i in 0...8 {
                let image = view.snapshot(size: CGSize(width: 600, height: 500), phase: CGFloat(i) / 8)
                let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name)-\(i).png"))
            }
            print("\(name): 9 frames \(Int(Date().timeIntervalSince(built) * 1000)) ms")
        }
    }
}

// MARK: - App Actions web pages and My Wheel

extension FileActionsTests {
    @Test func webPageAddressesAreHTTPSOrLocalAndNeverCarryCredentialsOrHiddenText() throws {
        #expect(FileAppTarget.pageURL(from: "example.com/upload")?.absoluteString == "https://example.com/upload")
        #expect(FileAppTarget.pageURL(from: "  https://tinypng.com  ")?.absoluteString == "https://tinypng.com")
        for local in ["http://localhost:3000", "http://192.168.1.10:5000/upload", "http://nas.local", "http://10.0.0.5", "http://127.0.0.1:8080", "http://172.20.1.1"] {
            #expect(FileAppTarget.pageURL(from: local) != nil, "\(local)")
        }
        for bad in ["", "http://example.com", "http://172.32.0.1", "http://192.168.1.300", "javascript:alert(1)", "file:///etc/passwd",
                    "ftp://example.com", "mailto:someone@example.com", "https://user:secret@example.com", "https://exa mple.com",
                    "https://example.com/\u{202E}gpj", "https://exam\u{200B}ple.com/up", "data:text/html,hi", "https://"] {
            #expect(FileAppTarget.pageURL(from: bad) == nil, "\(bad)")
        }
        let page = FileAppTarget(id: "page", name: "Upload", bundleID: "", appPath: "", delivery: .copyAndOpenPage, webAddress: "www.example.com/up")
        #expect(page.isValid && page.isWebPage && page.pageHost == "example.com")
        var wrong = page; wrong.delivery = .openFiles
        #expect(!wrong.isValid)
        wrong = page; wrong.webAddress = "http://example.com"
        #expect(!wrong.isValid)
        let app = FileAppTarget(id: "app", name: "Word", bundleID: "com.microsoft.Word", appPath: "", delivery: .copyAndOpenPage)
        #expect(!app.isValid)
        // Saved before web pages existed: no webAddress key, still an application.
        let old = #"{"id":"old","name":"Preview","bundleID":"com.apple.Preview","appPath":"","delivery":"openFiles","extensions":[],"enabled":true}"#
        let decoded = try JSONDecoder().decode(FileAppTarget.self, from: Data(old.utf8))
        #expect(!decoded.isWebPage && decoded.isValid)
        #expect(try JSONDecoder().decode(FileAppTarget.self, from: JSONEncoder().encode(page)) == page)
    }

    @Test func webPageActionsOpenOnlyThePageAndCopyFilesAfterItOpens() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let browser = dir.appendingPathComponent("Browser.app", isDirectory: true)
        try FileManager.default.createDirectory(at: browser.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "local.swivel.browser-fixture", "CFBundlePackageType": "APPL", "CFBundleName": "Browser"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: browser.appendingPathComponent("Contents/Info.plist"))
        let source = try file(dir, "secret plan.txt")
        let keys = ["feature.appRouting"] + Prefs.fileAppTargetKeys, defaults = UserDefaults.standard
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        Prefs.setFeatureEnabled(.appRouting, true)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        pasteboard.setString("keep clipboard", forType: .string)
        let target = FileAppTarget(id: "upload", name: "Upload", bundleID: "local.swivel.browser-fixture", appPath: browser.path,
                                   delivery: .copyAndOpenPage, webAddress: "https://example.com/upload?from=swivel")
        Prefs.fileAppTargets = [target]
        #expect(Prefs.fileAppTargets == [target])
        await #expect(throws: (any Error).self) {
            try await FileAppRouting.run(target, files: [source], pasteboard: pasteboard) { _, _ in throw ToolError("open failed") }
        }
        #expect(pasteboard.string(forType: .string) == "keep clipboard")
        var opened: [URL] = []
        let result = try await FileAppRouting.run(target, files: [source], pasteboard: pasteboard) { urls, app in
            opened = urls; #expect(app == browser)
        }
        // Exactly the address the user typed: nothing about the file reaches the browser.
        #expect(opened == [URL(string: "https://example.com/upload?from=swivel")!])
        #expect(!opened[0].absoluteString.contains("secret"))
        #expect(ToolUI.fileURLs(from: pasteboard) == [source])
        #expect(result.message == L("Drag the files from the card into %@, or paste them there with ⌘V.", "Upload"))
        // No browser chosen: the default one, whichever opens https pages.
        let plain = FileAppTarget(id: "plain", name: "Plain", bundleID: "", appPath: "", delivery: .copyAndOpenPage, webAddress: "https://example.com")
        #expect(FileAppRouting.application(for: plain) == NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!))
    }

    @Test func applicationListIncludesAppsInsideSuiteFolders() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        func app(_ path: String, _ id: String) throws {
            let url = dir.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        }
        try app("Word.app", "local.test.word")
        try app("Adobe Photoshop 2025/Adobe Photoshop 2025.app", "local.test.photoshop")
        try app("Adobe Acrobat DC/Adobe Acrobat.app", "local.test.acrobat")
        try app("Suite/Deeper/Hidden.app", "local.test.too-deep")
        try app("Word.app/Contents/Helpers/Helper.app", "local.test.helper")
        try app("Swivel.app", "local.swivel.app")
        let names = AppTargetEditor.installedApplications(in: [dir.path]).map { $0.deletingPathExtension().lastPathComponent }
        #expect(names == ["Adobe Acrobat", "Adobe Photoshop 2025", "Word"])
    }

    @Test func myWheelKeepsItsOwnKeyAndOnlyTakesOneWhenAsked() {
        let defaults = UserDefaults.standard, keys = WheelMode.allCases.map { "key." + $0.id } + ["customWheel.items"]
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        keys.forEach(defaults.removeObject(forKey:))
        #expect(Prefs.key(for: .custom) == .off && Prefs.key(for: .apps) == .option)
        #expect(!TriggerKey.off.isTapped(in: [.option, .shift, .command, .control, .function]))
        Prefs.customWheelItems = ["convert/PNG"]
        #expect(WheelMode.tapped([.option]) == .apps || !WheelMode.apps.isAvailable)
        // Giving My Wheel Option swaps: App Actions takes My Wheel's old key, none.
        Prefs.setKey(.option, for: .custom)
        #expect(Prefs.key(for: .custom) == .option && Prefs.key(for: .apps) == .off)
        #expect(WheelMode.tapped([.option]) == .custom)
        #expect(WheelMode.tapped([]) == nil)
        Prefs.customWheelItems = []
        #expect(WheelMode.tapped([.option]) == nil)  // nothing picked: no empty wheel
        Prefs.setKey(.off, for: .custom)
        #expect(Prefs.key(for: .custom) == .off && Prefs.key(for: .apps) == .off)
        Prefs.resetKeys()
        #expect(Prefs.key(for: .custom) == .off && Prefs.key(for: .apps) == .option && Prefs.key(for: .convert) == .shift)
    }

    @Test func myWheelShowsPickedActionsThatFitTheFilesInTheUsersOrder() throws {
        let defaults = UserDefaults.standard, keys = ["customWheel.items", "feature.appRouting"] + Prefs.fileAppTargetKeys
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        Prefs.setFeatureEnabled(.appRouting, true)
        let text = FileAppTarget(id: "text-app", name: "Text App", bundleID: "", appPath: "", delivery: .openFiles, extensions: ["txt"])
        Prefs.fileAppTargets = [text]
        Prefs.customWheelItems = ["actions/Copy Path", "bogus", "custom/loop", "convert/", "convert/PNG", "apps/app.text-app", "convert/PNG", "convert/M4A"]
        #expect(Prefs.customWheelItems == ["actions/Copy Path", "convert/PNG", "apps/app.text-app", "convert/M4A"])
        let candidates = Set(CustomWheel.candidates().map(\.id))
        #expect(candidates.isSuperset(of: ["actions/Copy Path", "convert/PNG", "convert/M4A", "apps/app.text-app"]))
        #expect(!candidates.contains { $0.hasPrefix("custom/") })
        let photo = URL(fileURLWithPath: "/nonexistent/photo.jpg"), song = URL(fileURLWithPath: "/nonexistent/song.wav")
        #expect(Catalog.items(for: [photo], mode: .custom).map(\.title) == ["Copy Path", "PNG"])
        #expect(Catalog.items(for: [song], mode: .custom).map(\.title) == ["Copy Path", "M4A"])
        #expect(Catalog.items(for: [URL(fileURLWithPath: "/nonexistent/notes.txt")], mode: .custom).map(\.title) == ["Copy Path", "app.text-app"])
        // Opened by the shortcut, with no files: every picked action that is available.
        #expect(CustomWheel.items(for: []).map(\.title) == ["Copy Path", "PNG", "app.text-app", "M4A"])
        #expect(CustomWheel.label(CustomWheel.Ref(id: "convert/PNG")!) == WheelMode.convert.title + " · PNG")
        // An app that is turned off leaves My Wheel's list but stays picked, in its place, for when it's back.
        var off = text; off.enabled = false; Prefs.fileAppTargets = [off]
        #expect(CustomWheel.items(for: []).map(\.title) == ["Copy Path", "PNG", "M4A"])
        let rows: [(title: String, shown: Bool)] = [("convert/M4A", true), ("actions/Copy Path", true), ("convert/PNG", false)]
        #expect(Arrangement.mergedPicks(rows: rows, stored: Prefs.customWheelItems) == ["convert/M4A", "actions/Copy Path", "apps/app.text-app"])
        // Quick Actions doesn't list My Wheel's actions a second time.
        #expect(!QuickActions.makeCommands(files: [photo]).contains { $0.id.hasPrefix("custom.") })
    }

    @Test func recordedShortcutsNeedACommandKeyAndSurviveSaving() throws {
        let defaults = UserDefaults.standard, before = defaults.object(forKey: "customWheel.shortcut")
        defer { if let before { defaults.set(before, forKey: "customWheel.shortcut") } else { defaults.removeObject(forKey: "customWheel.shortcut") } }
        let m = try KeyCombo.recorded(keyCode: UInt16(kVK_ANSI_M), flags: [.control, .option], characters: "m").get()
        #expect(m.title == "⌃⌥ M" && m.modifiers == UInt32(controlKey | optionKey) && m.keyCode == UInt32(kVK_ANSI_M))
        let space = try KeyCombo.recorded(keyCode: UInt16(kVK_Space), flags: [.command, .shift], characters: " ").get()
        #expect(space.title == "⇧⌘ Space")
        #expect((try? KeyCombo.recorded(keyCode: UInt16(kVK_ANSI_M), flags: [.shift], characters: "M").get()) == nil)
        #expect((try? KeyCombo.recorded(keyCode: UInt16(kVK_ANSI_M), flags: [], characters: "m").get()) == nil)
        #expect((try? KeyCombo.recorded(keyCode: 200, flags: [.command], characters: "x").get()) == nil)
        #expect((try? KeyCombo.recorded(keyCode: UInt16(kVK_ANSI_M), flags: [.command], characters: "\u{200B}").get()) == nil)
        Prefs.customWheelShortcut = m
        #expect(Prefs.customWheelShortcut == m)
        Prefs.customWheelShortcut = nil
        #expect(Prefs.customWheelShortcut == nil && defaults.object(forKey: "customWheel.shortcut") == nil)
        defaults.set(try JSONEncoder().encode(KeyCombo(keyCode: 46, modifiers: 0, key: "M")), forKey: "customWheel.shortcut")
        #expect(Prefs.customWheelShortcut == nil)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "µ", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: UInt16(kVK_ANSI_M))!
        #expect(m.matches(event) && !space.matches(event))
    }
}

// MARK: - Review fixes: shortcuts, saved app targets, local addresses, My Wheel availability

extension FileActionsTests {
    @Test func recordedShortcutsNeverTakeOrdinaryAppShortcutsOrTyping() throws {
        let defaults = UserDefaults.standard, before = defaults.object(forKey: "customWheel.shortcut")
        defer { if let before { defaults.set(before, forKey: "customWheel.shortcut") } else { defaults.removeObject(forKey: "customWheel.shortcut") } }
        func record(_ code: Int, _ flags: NSEvent.ModifierFlags, _ characters: String = "k") -> Result<KeyCombo, ToolError> {
            KeyCombo.recorded(keyCode: UInt16(code), flags: flags, characters: characters)
        }
        // ⌘ or ⌃ with one key belongs to apps (copy, paste, quit, close, save, app switcher…).
        for code in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_N,
                     kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_F, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_Comma, kVK_Tab, kVK_Space] {
            #expect((try? record(code, [.command]).get()) == nil, "⌘ \(code)")
            #expect((try? record(code, [.control]).get()) == nil, "⌃ \(code)")
        }
        // ⌥ and ⌥⇧ type accented characters.
        for flags: NSEvent.ModifierFlags in [[.option], [.option, .shift]] {
            guard case .failure(let problem) = record(kVK_ANSI_E, flags, "e") else { Issue.record("⌥ E was accepted"); continue }
            #expect(problem.message == L("⌥ and ⇧ type special characters. Add ⌃ or ⌘ to the shortcut."))
        }
        guard case .failure(let single) = record(kVK_ANSI_C, [.command], "c") else { Issue.record("⌘C was accepted"); return }
        #expect(single.message == L("Apps use ⌘ or ⌃ with one key. Add another modifier, such as ⌃⌥ or ⌘⇧, or use a function key."))
        // Two modifiers, or a function key with one.
        for flags: NSEvent.ModifierFlags in [[.control, .option], [.command, .shift], [.command, .option], [.control, .command], [.control, .shift], [.control, .option, .shift]] {
            #expect((try? record(kVK_ANSI_K, flags).get()) != nil, "\(flags)")
        }
        for flags: NSEvent.ModifierFlags in [[.command], [.option], [.control]] {
            #expect((try? record(kVK_F5, flags, "").get())?.key == "F5", "\(flags)")
        }
        #expect((try? record(kVK_F5, [.shift], "").get()) == nil)
        #expect((try? record(kVK_ANSI_K, [.control, .option], "\u{200B}").get()) == nil)
        // A saved shortcut that older rules allowed (⌘C, ⌥⇧E) is ignored when read.
        defaults.set(try JSONEncoder().encode(KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey), key: "C")), forKey: "customWheel.shortcut")
        #expect(Prefs.customWheelShortcut == nil)
        defaults.set(try JSONEncoder().encode(KeyCombo(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(optionKey | shiftKey), key: "E")), forKey: "customWheel.shortcut")
        #expect(Prefs.customWheelShortcut == nil)
    }

    @Test func otherSwivelShortcutsClashEvenWhileTheirToolIsOff() {
        let defaults = UserDefaults.standard, keys = ["feature.quickActions", "feature.clothesline"]
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        Prefs.setFeatureEnabled(.quickActions, false)
        Prefs.setFeatureEnabled(.clothesline, false)
        let quick = Prefs.quickShortcut
        #expect(KeyCombo(keyCode: quick.keyCode, modifiers: quick.modifiers, key: "X").isUsedBySwivel)
        #expect(KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey), key: "T").isUsedBySwivel)
        #expect(KeyCombo(keyCode: Prefs.wheelShortcut.keyCode, modifiers: UInt32(controlKey | optionKey), key: "X").isUsedBySwivel)
        #expect(!KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey), key: "M").isUsedBySwivel)
    }

    /// FileAppTarget as Swivel 1.6 decoded it: four deliveries, no web pages.
    private struct LegacyTarget: Codable {
        enum Delivery: String, Codable { case openFiles, codexDraft, claudeCodeDraft, copyFiles }
        let id: String, name: String, bundleID: String, appPath: String, delivery: Delivery, extensions: [String], enabled: Bool
    }

    @Test func savedAppTargetsStayReadableByOlderBuildsAndOneBadEntryLosesNothingElse() throws {
        let defaults = UserDefaults.standard, keys = Prefs.fileAppTargetKeys
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let app = FileAppTarget(id: "preview", name: "Preview", bundleID: "com.apple.Preview", appPath: "", delivery: .openFiles)
        let page = FileAppTarget(id: "page", name: "Upload", bundleID: "", appPath: "", delivery: .copyAndOpenPage, webAddress: "example.com/up")
        let other = FileAppTarget(id: "draft", name: "Codex", bundleID: "", appPath: "", delivery: .codexDraft)
        Prefs.fileAppTargets = [app, page, other]
        #expect(Prefs.fileAppTargets == [app, page, other])
        // 1.6 reads the applications from the list it knows.
        let legacy = try JSONDecoder().decode([LegacyTarget].self, from: #require(defaults.data(forKey: "appTargets.v1")))
        #expect(legacy.map(\.id) == ["preview", "draft"])
        Prefs.fileAppTargets = [page, other, app]
        #expect(Prefs.fileAppTargets == [page, other, app])
        // 1.6 saving its own list back (one app removed) keeps the pages; an app it added lands at the end.
        let added = LegacyTarget(id: "new", name: "TextEdit", bundleID: "com.apple.TextEdit", appPath: "", delivery: .openFiles, extensions: [], enabled: true)
        let kept = LegacyTarget(id: "draft", name: "Codex", bundleID: "", appPath: "", delivery: .codexDraft, extensions: [], enabled: true)
        defaults.set(try JSONEncoder().encode([kept, added]), forKey: "appTargets.v1")
        #expect(Prefs.fileAppTargets.map(\.id) == ["page", "draft", "new"])
        // A list with an entry this build can't read (a future delivery) and a page saved in it, as 1.7.0 did.
        let mixed = #"""
        [{"id":"future","name":"Future","bundleID":"","appPath":"","delivery":"teleport","extensions":[],"enabled":true},
         {"id":"preview","name":"Preview","bundleID":"com.apple.Preview","appPath":"","delivery":"openFiles","extensions":[],"enabled":true},
         {"id":"page","name":"Upload","bundleID":"","appPath":"","delivery":"copyAndOpenPage","extensions":[],"enabled":true,"webAddress":"example.com/up"}]
        """#
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(Data(mixed.utf8), forKey: "appTargets.v1")
        #expect(Prefs.fileAppTargets == [app, page])
        defaults.set(Data("not json".utf8), forKey: "appTargets.v1")
        #expect(Prefs.fileAppTargets == FileAppTarget.starters)
        for key in keys { defaults.removeObject(forKey: key) }
        #expect(Prefs.fileAppTargets == FileAppTarget.starters)
    }

    @Test func localAddressesAreCanonicalDecimalAndHostsCarryNoEscapes() {
        for bad in ["http://010.0.0.1", "http://0127.0.0.1", "http://+127.0.0.1", "http://10.0.0.01", "http://127.0.0.1.", "http://0x7f.0.0.1",
                    "http://127.1", "http://2130706433", "https://exa%2Fmple.com", "https://example.com%23.evil.com", "https://a%3Fb.com",
                    "https://a%00b.com", "https://%65xample.com"] {
            #expect(FileAppTarget.pageURL(from: bad) == nil, "\(bad)")
        }
        for host in ["010.0.0.1", "0127.0.0.1", "+127.0.0.1", "127.0.0.+1", "1٠.0.0.1", "10.0.0.1000"] { #expect(!FileAppTarget.isLocal(host), "\(host)") }
        for host in ["10.0.0.0", "127.0.0.1", "192.168.0.10", "172.16.0.1", "169.254.1.1"] { #expect(FileAppTarget.isLocal(host), "\(host)") }
        #expect(FileAppTarget.pageURL(from: "example.com/upload?next=https://other.example/x")?.absoluteString == "https://example.com/upload?next=https://other.example/x")
        #expect(FileAppTarget.pageURL(from: "localhost:3000/cb?back=http://x")?.host == "localhost")
        #expect(FileAppTarget.pageURL(from: "https://例子.com/up") != nil)
        #expect(FileAppTarget.pageURL(from: "http://10.0.0.5:8080") != nil)
    }

    @Test func myWheelKeyNeedsAPickThatStillResolves() {
        let defaults = UserDefaults.standard, keys = ["customWheel.items", "feature.appRouting"] + Prefs.fileAppTargetKeys
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        Prefs.setFeatureEnabled(.appRouting, true)
        Prefs.fileAppTargets = [FileAppTarget(id: "kept-app", name: "Kept", bundleID: "", appPath: "", delivery: .openFiles)]
        Prefs.customWheelItems = ["apps/app.deleted", "tools/preset.deleted", "convert/NoSuchFormat"]
        #expect(!Prefs.customWheelItems.isEmpty && !WheelMode.custom.isAvailable)
        Prefs.customWheelItems = ["apps/app.deleted", "apps/app.kept-app"]
        #expect(WheelMode.custom.isAvailable)
        Prefs.setFeatureEnabled(.appRouting, false)
        #expect(!WheelMode.custom.isAvailable)
        Prefs.customWheelItems = ["apps/app.deleted", "actions/Copy Path"]
        #expect(WheelMode.custom.isAvailable)
        Prefs.customWheelItems = []
        #expect(!WheelMode.custom.isAvailable)
    }

    @Test func wordCountResultIsTranslated() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let note = try file(dir, "note.txt", "one two three")
        let expected = L("%@: %ld words, %ld characters", "note.txt", 3, 13)
        #expect(expected.contains("3") && expected.contains("13"))
        await #expect { try await Docs.wordCount(note) } throws: { ($0 as? Info)?.message == expected }
        #expect(Strings.table["%@: %ld words, %ld characters"]?.count == 3)
    }
}
