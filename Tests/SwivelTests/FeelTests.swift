import AppKit
import Testing
@testable import Swivel

/// The motion and feedback building blocks: springs must be exact and continuous, menus must hit-test stably.
@Suite(.serialized)
@MainActor
struct FeelTests {
    private func run(_ spring: inout Spring, for seconds: CGFloat, step: CGFloat = 1.0 / 120) {
        var t: CGFloat = 0
        while t < seconds - 1e-9 {
            spring.step(step)
            t += step
        }
    }

    @Test func testCriticallyDampedSpringSettlesOnSchedule() {
        // ζ = 1: within 5 % of the target at 0.755 × response, within 1 % at 1.06 × response.
        var spring = Spring(0, response: 0.4, damping: 1)
        spring.target = 1
        run(&spring, for: 0.755 * 0.4)
        #expect(abs(spring.value - 0.95) < 0.01)
        run(&spring, for: (1.06 - 0.755) * 0.4)
        #expect(spring.value > 0.985 && spring.value <= 1)
    }

    @Test func testUnderdampedSpringOvershootsByTheTextbookAmount() {
        // ζ = 0.62 overshoots by e^(−πζ/√(1−ζ²)) ≈ 8.35 %.
        var spring = Spring(0, response: 0.24, damping: 0.62)
        spring.target = 1
        var peak: CGFloat = 0
        for _ in 0..<240 {
            spring.step(1.0 / 480)
            peak = max(peak, spring.value)
        }
        #expect(abs(peak - 1.0835) < 0.005)
    }

    @Test func testRetargetingMidFlightKeepsPositionAndVelocity() {
        var spring = Spring(0, response: 0.24, damping: 0.62)
        spring.target = 1
        run(&spring, for: 0.05)
        let (value, velocity) = (spring.value, spring.velocity)
        spring.target = 0
        spring.damping = 0.95
        #expect(spring.value == value && spring.velocity == velocity)
        // The next millisecond continues along the old velocity: no jump, no "brick wall".
        spring.step(1.0 / 1000)
        #expect(abs(spring.value - (value + velocity / 1000)) < 0.001)
    }

    @Test func testStepSizeDoesNotChangeTheMotion() {
        // Solved analytically, so one 30 fps frame equals four 120 fps frames.
        var coarse = Spring(0, response: 0.3, damping: 0.7), fine = coarse
        coarse.target = 1
        fine.target = 1
        coarse.step(1.0 / 30)
        for _ in 0..<4 { fine.step(1.0 / 120) }
        #expect(abs(coarse.value - fine.value) < 1e-6)
        #expect(abs(coarse.velocity - fine.velocity) < 1e-4)
    }

    @Test func testSpringSettlesAndStopsAtTarget() {
        var spring = Spring(2, response: 0.2, damping: 0.8)
        spring.target = -1
        run(&spring, for: 2)
        #expect(spring.isSettled)
        #expect(spring.value == -1 && spring.velocity == 0)
    }

    private func wheel(_ count: Int = 8) -> WheelView {
        let view = WheelView(frame: NSRect(origin: .zero, size: WheelView.size(for: .wheel, count: count, live: true)))
        view.unregisterDraggedTypes()
        view.configure(items: (0..<count).map { WheelItem(title: "Item \($0)") { _ in ActionResult(message: "") } },
                       mode: .convert, page: 0, pageCount: 1)
        return view
    }

    private func point(_ view: WheelView, degrees: CGFloat, radius: CGFloat) -> NSPoint {
        NSPoint(x: view.bounds.midX + cos(degrees * .pi / 180) * radius, y: view.bounds.midY + sin(degrees * .pi / 180) * radius)
    }

    @Test func testWheelSelectsByAngleWithHysteresisAndAHubDeadZone() {
        let view = wheel()
        #expect(view.track(point(view, degrees: 90, radius: 20)) == false)          // hub: nothing
        #expect(view.track(point(view, degrees: 90, radius: 90)) && view.hovered == 0)
        // Sector 0 spans 67.5°–112.5°. Just past its edge it stays chosen…
        view.track(point(view, degrees: 64, radius: 90))
        #expect(view.hovered == 0)
        // …and well past it the next sector (clockwise) takes over.
        view.track(point(view, degrees: 55, radius: 90))
        #expect(view.hovered == 1)
        // Past the ring (a flick that overshoots) still selects by angle…
        view.track(point(view, degrees: 0, radius: 160))
        #expect(view.hovered == 2)
        // …but well away from it is empty space, where releasing cancels.
        view.track(point(view, degrees: 0, radius: 185))
        #expect(view.hovered == nil)
        view.track(point(view, degrees: 0, radius: 90))
        #expect(view.hovered == 2)
        // Falling back into the hub needs to go clearly inside it.
        view.track(point(view, degrees: 0, radius: 50))
        #expect(view.hovered == 2)
        view.track(point(view, degrees: 0, radius: 40))
        #expect(view.hovered == nil)
    }

    @Test func testWheelIgnoresTheFirstFewPointsAfterOpeningOffCentre() {
        let view = wheel()
        let start = point(view, degrees: 0, radius: 90)  // opened shifted, pointer already over a sector
        view.beginOpen(pointer: start)
        #expect(view.track(NSPoint(x: start.x + 4, y: start.y)) == false && view.hovered == nil)
        #expect(view.track(NSPoint(x: start.x + 12, y: start.y)) && view.hovered == 2)
    }

    @Test func testListRowsHaveNoDeadGapsBetweenThem() {
        let size = WheelView.size(for: .list, count: 4)
        let view = WheelView(frame: NSRect(origin: .zero, size: size))
        view.unregisterDraggedTypes()
        view.style = .list
        view.configure(items: (0..<4).map { WheelItem(title: "Row \($0)") { _ in ActionResult(message: "") } },
                       mode: .convert, page: 0, pageCount: 1)
        let top = size.height - WheelView.headerHeight - 4
        // Every point down the column belongs to some row, including the old 4 pt gaps.
        for y in stride(from: top - 1, to: top - 4 * WheelView.listRow + 1, by: -1) {
            #expect(view.track(NSPoint(x: size.width / 2, y: y)), "no row at y = \(y)")
        }
    }

    @Test func testStringsTableLoads() {
        // A duplicate key in the table's dictionary literal traps on first use, i.e. at launch.
        #expect(Strings.table.count > 300)
        #expect(Strings.table.values.allSatisfy { $0.count == 3 })
    }

    @Test func testInterfaceSoundsAreShortQuietAndStartImmediately() {
        for effect in Sounds.Effect.allCases {
            let samples = SoundSynth.samples(effect, pitch: 1, gain: 1)
            let peak = samples.map { abs($0) }.max() ?? 0
            #expect(peak > 0.03 && peak <= 0.23, "\(effect) peak \(peak)")
            #expect(samples.count <= 48_000 * 3 / 10, "\(effect) too long")
            #expect(abs(samples[0]) > 0 || abs(samples[1]) > 0, "\(effect) starts with silence")
            #expect(abs(samples.last ?? 1) < 0.001, "\(effect) clicks at the end")
        }
        let wav = SoundSynth.wav([0, 0.5, -0.5])
        #expect(wav.count == 44 + 6)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
    }
}
