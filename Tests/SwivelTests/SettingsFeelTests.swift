import AppKit
import Testing
@testable import Swivel

/// The Settings window's custom surfaces: template cards behave like buttons, reorder drops land in the right place,
/// and live menu previews map the pointer correctly and go back to rest when they leave the screen.
@Suite(.serialized)
@MainActor
struct SettingsFeelTests {
    @Test func testClickPressesOnDownAndCommitsOnlyOnReleaseInside() {
        var click = ClickTracker()
        #expect(!click.showsPressed)
        click.down()
        #expect(click.showsPressed)
        click.drag(inside: false)  // dragged off: looks released, a release here cancels
        #expect(!click.showsPressed)
        click.drag(inside: true)   // back on: pressed again
        #expect(click.showsPressed)
        let committed = click.up(inside: true)
        #expect(committed)
        #expect(!click.showsPressed && !click.isDown)

        click.down()
        #expect(click.up(inside: false) == false)
        // A release without a press (the press began elsewhere) never commits.
        #expect(click.up(inside: true) == false)
        click.drag(inside: true)
        #expect(!click.showsPressed)
    }

    @Test func testReorderDestinationMatchesArrayMove() {
        // Dropping above row `proposed` moves the row to the same index a remove + insert would.
        for count in 1...6 {
            for from in 0..<count {
                for proposed in 0...count {
                    var items = Array(0..<count)
                    let moved = items.remove(at: from)
                    let to = DropSlot.destination(from: from, proposed: proposed)
                    #expect((0..<count).contains(to))
                    items.insert(moved, at: to)
                    // Everything that was above the drop line stays above the moved row, everything below stays below.
                    let above = (0..<proposed).filter { $0 != from }
                    #expect(Array(items.prefix(above.count)) == above, "from \(from) above \(proposed) of \(count)")
                }
            }
        }
        // The gaps just above and just below the dragged row both mean "where it was".
        #expect(DropSlot.destination(from: 2, proposed: 2) == 2)
        #expect(DropSlot.destination(from: 2, proposed: 3) == 2)
    }

    @Test func testReorderDetentFiresOncePerNewPlace() {
        var slot = DropSlot()
        #expect(slot.move(to: 2) == false)  // where the drag starts
        #expect(slot.move(to: 2) == false)
        let moved = slot.move(to: 3)
        #expect(moved)
        #expect(slot.move(to: 3) == false)
        let movedBack = slot.move(to: 0)
        #expect(movedBack)
        slot.reset()
        #expect(slot.move(to: 4) == false)  // a new drag starts fresh
    }

    @Test func testCustomizeSaveKeepsStoredEntriesForItemsWhoseToolIsOff() {
        // Stored while Image Presets and Clothesline were on: the preset led the list and was hidden, Hang followed Copy.
        let storedOrder = ["preset.X", "Copy", "Hang", "Move", "AirDrop"]
        let storedHidden: Set<String> = ["preset.X", "Move"]
        // Both tools are off now, so Customize shows three rows; the user drags Move up and unticks Copy.
        let merged = Arrangement.merged(rows: [(title: "Move", shown: true), (title: "Copy", shown: false), (title: "AirDrop", shown: true)],
                                        storedOrder: storedOrder, storedHidden: storedHidden)
        #expect(merged.order == ["preset.X", "Move", "Copy", "Hang", "AirDrop"])
        // The rows decide for themselves (Move is shown again); the preset stays hidden.
        #expect(merged.hidden == ["preset.X", "Copy"])

        // A run of absent titles keeps its order after the title it followed, wherever that title moved to.
        let run = Arrangement.merged(rows: [(title: "B", shown: true), (title: "A", shown: true)],
                                     storedOrder: ["A", "X", "Y", "B", "Z"], storedHidden: ["Y", "Z"])
        #expect(run.order == ["B", "Z", "A", "X", "Y"])
        #expect(run.hidden == ["Y", "Z"])

        // With everything present (or nothing stored) the rows are saved exactly as shown, as before.
        let rows = [(title: "A", shown: true), (title: "B", shown: false)]
        #expect(Arrangement.merged(rows: rows, storedOrder: [], storedHidden: []).order == ["A", "B"])
        let present = Arrangement.merged(rows: rows, storedOrder: ["B", "A"], storedHidden: ["A"])
        #expect(present.order == ["A", "B"] && present.hidden == ["B"])
        // A title stored twice is put back once.
        #expect(Arrangement.merged(rows: rows, storedOrder: ["X", "A", "X"], storedHidden: []).order == ["X", "A", "B"])
    }

    private func host(_ style: MenuStyle = .wheel, hovered: Int? = 1) -> PreviewHost {
        let host = PreviewHost(frame: NSRect(x: 0, y: 0, width: 250, height: 170))
        host.show(menuPreview(style: style, titles: ["JPG", "PNG", "HEIC", "WebP", "TIFF", "GIF", "PDF"], mode: .convert,
                              hovered: hovered))
        host.layoutSubtreeIfNeeded()
        return host
    }

    @Test func testPreviewPointsAreInTheMenusOwnUnscaledCoordinates() throws {
        let host = host()
        let preview = try #require(host.preview)
        let natural = WheelView.size(for: .wheel, count: 7)
        #expect(preview.bounds.size == natural)
        // The 320 pt wheel is drawn scaled down into the card, centred: the host's centre is the wheel's centre.
        let centre = try #require(host.previewPoint(forWindowPoint: NSPoint(x: host.bounds.midX, y: host.bounds.midY)))
        #expect(abs(centre.x - natural.width / 2) < 0.5 && abs(centre.y - natural.height / 2) < 0.5)
        // The top edge of the drawn wheel is the top of its natural bounds.
        let top = try #require(host.previewPoint(forWindowPoint: NSPoint(x: preview.frame.midX, y: preview.frame.maxY - 0.01)))
        #expect(abs(top.y - natural.height) < 1)
        // The margin around the scaled menu isn't part of it.
        #expect(host.previewPoint(forWindowPoint: NSPoint(x: 2, y: 2)) == nil)
    }

    @Test func testStaticPreviewDrawsSettledAndIsNotLiveOffScreen() throws {
        let host = host()
        let preview = try #require(host.preview)
        #expect(preview.hovered == 1)
        #expect(preview.isLive == false)
        host.isInteractive = false
        #expect(preview.isLive == false)
    }

    @Test func testPreviewIsLiveOnlyInAWindowAndComesBackAtRest() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = container
        let host = host()
        let preview = try #require(host.preview)
        container.addSubview(host)
        #expect(preview.isLive)
        // Pressed mid-try (pressing sets the hover without a hover tick), then the page goes away.
        preview.beginConfirm(4)
        #expect(preview.pressed == 4 && preview.hovered == 4)
        host.removeFromSuperview()
        #expect(preview.isLive == false)
        #expect(preview.pressed == nil)
        #expect(preview.hovered == 1)  // the resting picture again
        #expect(preview.cancelArmed == false)
        // Back on screen it is live again; a static (non-interactive) host never is.
        container.addSubview(host)
        #expect(preview.isLive)
        host.isInteractive = false
        #expect(preview.isLive == false && preview.hovered == 1)
        window.close()
    }

    @Test func testPreviewRestingHoverIsNotAVisitSoEmptySpotsDontCancel() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = container
        // Styles with a header band and gaps: their top centre isn't an item.
        for style in [MenuStyle.list, .shelf, .notes, .clothesline] {
            let host = host(style)
            let preview = try #require(host.preview)
            container.addSubview(host)
            #expect(preview.isLive)
            let top = NSPoint(x: preview.bounds.midX, y: preview.bounds.maxY - 1)
            // First entry over the header: the resting hover doesn't count, so this isn't "Cancel".
            #expect(preview.track(top) == false)
            #expect(preview.hovered == nil && preview.cancelArmed == false, "\(style) after first entry")

            // After leaving the screen it rests on its hovered item again, which still isn't a visit.
            host.removeFromSuperview()
            #expect(preview.hovered == 1)
            container.addSubview(host)
            preview.track(top)
            #expect(preview.hovered == nil && preview.cancelArmed == false, "\(style) after coming back")

            // A try that visited an item, left, and comes back in starts afresh. (The visit is set while not live
            // so the test makes no sound.)
            preview.isLive = false
            preview.hovered = 3
            preview.isLive = true
            preview.pointerLeft()
            let entry = NSPoint(x: preview.frame.midX, y: preview.frame.maxY - 0.5)  // host and window share coordinates
            #expect(host.previewPoint(forWindowPoint: entry) != nil)
            host.mouseEntered(with: event(.mouseMoved, at: entry))
            #expect(preview.hovered == nil && preview.cancelArmed == false, "\(style) on a new entry")
            host.removeFromSuperview()
        }
        window.close()
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func testTemplateCardIsOneButtonAroundALivePreview() {
        let card = TemplateCard(.list)
        card.frame = NSRect(x: 0, y: 0, width: 250, height: 250)
        card.layoutSubtreeIfNeeded()
        var picks: [MenuStyle] = []
        card.onPick = { picks.append($0) }

        // Labels and margins belong to the card; the preview area belongs to the preview.
        #expect(card.hitTest(NSPoint(x: 125, y: 20)) === card)
        let inPreview = card.hitTest(NSPoint(x: 125, y: 160))
        #expect(inPreview != nil && inPreview !== card)

        card.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 125, y: 20)))
        #expect(picks.isEmpty)  // nothing is chosen until the release
        card.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 125, y: 20)))
        #expect(picks == [.list])

        // Dragging off before letting go cancels.
        card.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 125, y: 20)))
        card.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 400, y: 20)))
        card.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 400, y: 20)))
        #expect(picks == [.list])

        card.setSelected(true)
        #expect(card.isSelected && (card.accessibilityValue() as? NSNumber)?.boolValue == true)
        #expect(card.accessibilityRole() == .radioButton)
    }
}
