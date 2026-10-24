import AppKit
import Testing
@testable import Swivel

/// The pure logic behind the tools' feedback: what the shelf highlights and restores, which preset field gets
/// pointed at, and where the quality slider rests. Also where the keyboard goes: Return in Text Capture, Quick
/// Actions closing behind a command's picker, and Quick Look handing activation back.
@Suite(.serialized)
@MainActor
struct ToolsFeelTests {
    private func files(_ names: [String]) throws -> (folder: URL, urls: [URL]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwivelFeel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = names.map { folder.appendingPathComponent($0) }
        for url in urls { try Data(url.lastPathComponent.utf8).write(to: url) }
        return (folder, urls)
    }

    @Test func testShelfReportsWhatArrivedAndWhatWasAlreadyThere() throws {
        let (folder, urls) = try files(["a.txt", "b.txt", "c.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let (a, b, c) = (urls[0], urls[1], urls[2])
        var shelf = ShelfContents()
        let first = shelf.add([a, b, a])
        #expect(first.added == IndexSet([0, 1]))
        #expect(first.existing.isEmpty)
        let second = shelf.add([b, c, folder.appendingPathComponent("missing.txt")])
        #expect(second.added == IndexSet([2]))
        #expect(second.existing == IndexSet([1]))
        #expect(shelf.urls == [a, b, c])
    }

    @Test func testShelfUndoPutsReferencesBackInPlace() throws {
        let (folder, urls) = try files(["0.txt", "1.txt", "2.txt", "3.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        var shelf = ShelfContents()
        shelf.add(urls)
        let removed = [(offset: 0, url: urls[0]), (offset: 2, url: urls[2])]
        shelf.remove([0, 2])
        #expect(shelf.urls == [urls[1], urls[3]])
        let rows = shelf.restore(removed)
        #expect(shelf.urls == urls)
        #expect(rows == IndexSet([0, 2]))
    }

    @Test func testShelfUndoSkipsFilesAddedAgainAndClampsPositions() throws {
        let (folder, urls) = try files(["0.txt", "1.txt", "2.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        var shelf = ShelfContents()
        shelf.add(urls)
        shelf.clear()
        shelf.add([urls[1]])
        let rows = shelf.restore([(offset: 0, url: urls[0]), (offset: 1, url: urls[1]), (offset: 2, url: urls[2])])
        #expect(shelf.urls == [urls[0], urls[1], urls[2]])
        #expect(rows == IndexSet([0, 2]))
        var short = ShelfContents()
        #expect(short.restore([(offset: 5, url: urls[2])]) == IndexSet([0]))
        #expect(short.urls == [urls[2]])
    }

    @Test func testPresetFormPointsAtTheFirstBadField() {
        #expect(ImagePreset.formIssue(name: "Web", longEdge: "1600") == nil)
        #expect(ImagePreset.formIssue(name: "Web", longEdge: " 0 ") == nil)
        #expect(ImagePreset.formIssue(name: "  ", longEdge: "1600") == .name)
        #expect(ImagePreset.formIssue(name: String(repeating: "x", count: 61), longEdge: "1600") == .name)
        #expect(ImagePreset.formIssue(name: "", longEdge: "abc") == .name)
        #expect(ImagePreset.formIssue(name: "Web", longEdge: "63") == .size)
        #expect(ImagePreset.formIssue(name: "Web", longEdge: "16385") == .size)
        #expect(ImagePreset.formIssue(name: "Web", longEdge: "1,600") == .size)
        #expect(ImagePreset.formIssue(name: "Web", longEdge: "") == .size)
        // Whatever the form accepts, the saved preset accepts too.
        var preset = ImagePreset.starters[0]
        preset.name = "Web"
        preset.longEdge = ImagePreset.longEdge(from: " 64 ") ?? -1
        #expect(preset.isValid)
    }

    @Test func testQualitySliderRestsOnRoundValuesButKeepsNeighbours() {
        #expect(QualityDetent.snap(79.4) == 80)
        #expect(QualityDetent.snap(80.7) == 80)
        #expect(QualityDetent.snap(81.2) == 81.2)
        #expect(QualityDetent.snap(9) == 9)
        #expect(QualityDetent.snap(11) == 11)
        #expect(QualityDetent.snap(99.5) == 100)
        #expect(QualityDetent.snap(1.3) == 1.3)
        #expect(QualityDetent.isDetent(90))
        #expect(!QualityDetent.isDetent(91))
        #expect(!QualityDetent.isDetent(0))
    }

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// Return reaches the default Copy button once the text is ready; inside the text it types a new line and
    /// ⌘Return copies. The window is never shown, so nothing appears on screen.
    @Test func testTextCaptureReturnCopiesUntilTheUserIsInTheText() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["feature.textCapture", "feedback.sounds"]
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        Prefs.setFeatureEnabled(.textCapture, true)
        Prefs.soundEffects = false
        let board = NSPasteboard(name: NSPasteboard.Name("SwivelTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let capture = TextCaptureWindow(URL(fileURLWithPath: "/tmp/swivel-capture-test.png"))
        capture.pasteboard = board
        let window = capture.window
        let text = capture.text
        // AppKit would focus the text as the window first appears; the window starts on Copy instead.
        #expect(window.initialFirstResponder is NSButton)

        // Even if the user clicked into the empty box while it was recognizing, focus leaves it once the text is in.
        window.makeFirstResponder(text)
        capture.showRecognized("Hello world")
        #expect(window.firstResponder !== text)
        window.sendEvent(key("\r", code: 36, in: window))
        #expect(text.string == "Hello world")
        #expect(board.string(forType: .string) == "Hello world")

        // Clicked into the text: Return is a new line, and only ⌘Return copies.
        board.clearContents()
        #expect(window.makeFirstResponder(text))
        text.setSelectedRange(NSRange(location: 5, length: 0))
        window.sendEvent(key("\r", code: 36, in: window))
        #expect(text.string == "Hello\n world")
        #expect(board.string(forType: .string) == nil)
        #expect(window.performKeyEquivalent(with: key("\r", code: 36, flags: .command, in: window)))
        #expect(board.string(forType: .string) == "Hello\n world")
    }

    /// Quick Actions blinks and closes on `ToolUI.after`, so it still closes while a command it started has an Open
    /// panel or alert up. Running the run loop in the modal-panel mode from inside this main-actor job stands in for
    /// that modal session; GCD's main queue would wait until the job ends.
    @Test func testDelayedCloseFiresWhileAModalSessionRuns() {
        @MainActor final class Box { var fired = false }
        let box = Box()
        let start = Date()
        ToolUI.after(0.02) { box.fired = true }
        while !box.fired, Date().timeIntervalSince(start) < 1 {
            _ = RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
        }
        #expect(box.fired)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    /// Closing a shelf preview gives activation back only to another app that's still running, only while Swivel is
    /// still active, and only once.
    @Test func testQuickLookHandsActivationBackOnlyWhenItShould() throws {
        let other = try #require(NSWorkspace.shared.runningApplications.first { $0 != NSRunningApplication.current && !$0.isTerminated })
        var handBack = ActivationReturn()
        handBack.remember(other)
        #expect(handBack.take(swivelIsActive: true) == other)
        #expect(handBack.take(swivelIsActive: true) == nil)
        // The user clicked into another app while previewing: leave activation where they put it.
        handBack.remember(other)
        #expect(handBack.take(swivelIsActive: false) == nil)
        #expect(handBack.app == nil)
        // Swivel itself (or nothing) was in front: nothing to give back.
        handBack.remember(.current)
        #expect(handBack.app == nil)
        handBack.remember(nil)
        #expect(handBack.take(swivelIsActive: true) == nil)
    }
}
