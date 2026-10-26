import AppKit
import Testing
@testable import Swivel

/// The window server has stopped putting Swivel's long-lived panels on the current Space in long sessions
/// (2026-10-24 card, 2026-10-26 rope). The fix moves the content into a fresh panel. That situation can't be made
/// on demand, so these check the move itself: the content survives, the new panel really reaches the screen, and
/// its animation still runs to the end there (a display link belongs to the window it was made for).
@Suite(.serialized)
@MainActor
struct PanelRecoveryTests {
    private func wait(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    @Test func theRopeMovesIntoAFreshPanelAndStillLowersAndLifts() throws {
        let clothesline = Clothesline.shared
        let screen = try #require(NSScreen.main)
        let first = clothesline.panel
        let rope = first.rope
        defer { clothesline.panel.orderOut(nil) }

        first.lower(on: screen)
        wait(0.4)
        #expect(Clothesline.reallyShown(first))

        clothesline.rebuildPanel()
        let second = clothesline.panel
        #expect(second !== first)
        #expect(second.rope === rope)            // the same view: its prints come along
        #expect(rope.window === second)
        #expect(!first.isVisible)
        #expect(!second.isVisible)               // starts hidden; lowering brings it in

        second.lower(on: screen)
        wait(0.4)
        #expect(Clothesline.reallyShown(second))
        #expect(!rope.isLifting)

        // Lifting finishes only through frames from the new panel's display link.
        second.raise()
        wait(3) { !second.isVisible }
        #expect(!second.isVisible)
        #expect(!Clothesline.reallyShown(second))

        // Again, from a rebuilt panel that is still down: nothing is lost or left on screen.
        second.lower(on: screen)
        wait(0.4)
        clothesline.rebuildPanel()
        #expect(!second.isVisible)
        #expect(clothesline.panel.rope === rope)
        clothesline.panel.lower(on: screen)
        wait(0.4)
        #expect(Clothesline.reallyShown(clothesline.panel))
    }

    /// Runs `body` with the clothesline on and the given panels treated as lost by the window server.
    private func withLostPanels(_ lost: @escaping () -> [NSWindow], _ body: () async throws -> Void) async rethrows {
        let real = Clothesline.reallyShown
        let wasOn = Prefs.clotheslineEnabled
        Clothesline.reallyShown = { window in lost().contains { $0 === window } ? false : real(window) }
        Clothesline.checksWhileStopped = true
        Prefs.clotheslineEnabled = true
        defer {
            Clothesline.reallyShown = real
            Clothesline.checksWhileStopped = false
            Prefs.clotheslineEnabled = wasOn
            Clothesline.shared.panel.orderOut(nil)
        }
        try await body()
    }

    private func settle(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    @Test func aLostRopeIsRebuiltByTheCheckAfterLowering() async throws {
        let clothesline = Clothesline.shared
        clothesline.rebuildPanel()          // start from a hidden panel
        let lost = clothesline.panel
        let rope = lost.rope
        try await withLostPanels({ [lost] }) {
            let frames = rope.frames
            clothesline.show(force: true)
            #expect(clothesline.panel === lost)        // nothing looked wrong yet
            try await settle(Clothesline.checkSeconds * 2 + 0.4)
            #expect(clothesline.panel !== lost)        // the check found it missing and moved the rope
            #expect(clothesline.panel.rope === rope)
            #expect(!lost.isVisible)
            #expect(Clothesline.reallyShown(clothesline.panel))
            #expect(rope.frames > frames)              // and it animates in the new panel
        }
    }

    @Test func aLostRopeIsRebuiltWhenShownHiddenOrToggled() async throws {
        let clothesline = Clothesline.shared
        let screen = try #require(NSScreen.main)
        var lost: [NSWindow] = []
        try await withLostPanels({ lost }) {
            // Shown: a visible but lost rope would make `lower` do nothing.
            clothesline.panel.lower(on: screen)
            try await settle(0.3)
            let first = clothesline.panel
            lost = [first]
            let frames = first.rope.frames
            clothesline.show(force: true)
            #expect(clothesline.panel !== first)
            try await settle(0.4)
            #expect(Clothesline.reallyShown(clothesline.panel))
            #expect(clothesline.panel.rope.frames > frames)

            // Hidden: swapped for a fresh hidden panel at once, not left waiting for frames that never come.
            let second = clothesline.panel
            lost = [second]
            clothesline.hide()
            #expect(clothesline.panel !== second)
            #expect(!second.isVisible && !clothesline.panel.isVisible)

            // Toggled with the shortcut: a lost rope counts as hidden, so one press shows it rather than hiding the
            // window nobody can see. (With no prints hung here, showing just swaps in the fresh panel.)
            clothesline.panel.lower(on: screen)
            try await settle(0.3)
            let third = clothesline.panel
            lost = [third]
            clothesline.toggle()
            #expect(clothesline.panel !== third)
            #expect(!third.isVisible)
            clothesline.hide()
        }
    }

    @Test func aPrintBeingDraggedOffIsNeverInterruptedByARebuild() async throws {
        let clothesline = Clothesline.shared
        clothesline.rebuildPanel()
        let lost = clothesline.panel
        try await withLostPanels({ [lost] }) {
            lost.rope.isDraggingItem = true
            clothesline.show(force: true)
            try await settle(Clothesline.checkSeconds * 2 + 0.3)
            #expect(clothesline.panel === lost)        // waited while the print was held
            lost.rope.isDraggingItem = false
            try await settle(Clothesline.checkSeconds * 2 + 0.4)
            #expect(clothesline.panel !== lost)        // then recovered
            #expect(Clothesline.reallyShown(clothesline.panel))
        }
    }

    @Test func aLostMenuReopensInAFreshPanelByItself() async throws {
        let controller = WheelController()
        var ran: [String] = []
        let items = (0..<5).map { i in
            WheelItem(title: "Item \(i)") { _ in ran.append("Item \(i)"); return ActionResult(message: "") }
        }
        let real = Clothesline.reallyShown
        var lost: [NSWindow] = []
        Clothesline.reallyShown = { window in lost.contains { $0 === window } ? false : real(window) }
        defer { Clothesline.reallyShown = real; controller.dismiss() }
        let first = controller.panel
        lost = [first]
        let wheel = first.wheel
        controller.showClickable(items)
        let generation = first.generation
        try await settle(0.6)
        let second = controller.panel
        #expect(second !== first)
        #expect(second.wheel === wheel)
        #expect(wheel.window === second)
        #expect(!first.isVisible)
        #expect(second.generation > generation)    // tokens from the old panel never match the new one
        #expect(wheel.items.map(\.title) == items.map(\.title))
        #expect(Clothesline.reallyShown(second))
        #expect(!second.ignoresMouseEvents)
        #expect(second.firstResponder === wheel)

        wheel.onClick?(items[2])
        for _ in 0..<100 where ran.isEmpty || second.isVisible { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ran == ["Item 2"])
        #expect(!second.isVisible)
    }

    @Test func aStalledFrameDriverRestartsOnTheNextStart() {
        let panel = NSPanel(contentRect: NSRect(x: 60, y: 60, width: 80, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let view = NSView(frame: panel.contentLayoutRect)
        panel.contentView = view
        panel.orderFrontRegardless()
        defer { panel.close() }
        let driver = FrameDriver(view: view)
        var frames = 0
        driver.onFrame = { _ in frames += 1; return true }
        driver.start()
        wait(0.3)
        #expect(frames > 0)
        #expect(driver.isRunning)
        // Ordered out mid-animation, the link stops firing but still exists.
        panel.orderOut(nil)
        wait(0.4)
        #expect(!driver.isRunning)             // a link that hasn't ticked for 0.25 s doesn't count
        panel.orderFrontRegardless()
        frames = 0
        driver.start()                         // replaced instead of ignored
        wait(0.3)
        #expect(frames > 0)
        driver.stop()
    }
}
