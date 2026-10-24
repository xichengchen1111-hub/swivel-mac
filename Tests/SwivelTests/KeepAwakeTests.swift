import AppKit
import IOKit.pwr_mgt
import Testing
@testable import Swivel

@Suite(.serialized)
@MainActor
struct KeepAwakeTests {
    /// This process's assertions as macOS reports them: name → type.
    private func assertions() -> [String: String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let all = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [:] }
        let mine = all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return Dictionary(mine.compactMap { entry in
            guard let name = entry["AssertName"] as? String, let type = entry["AssertType"] as? String else { return nil }
            return (name, type)
        }, uniquingKeysWith: { first, _ in first })
    }

    private func withFeature(_ on: Bool, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard, keys = ["feature.keepAwake", "keepAwake.display"]
        let before = keys.map { defaults.object(forKey: $0) }
        defer {
            KeepAwake.shared.stop()
            for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
        }
        Prefs.setFeatureEnabled(.keepAwake, on)
        try body()
    }

    @Test func timedSessionsHoldAnAssertionAndReleaseItWhenStopped() {
        withFeature(true) {
            Prefs.keepAwakeDisplay = true
            KeepAwake.shared.start(for: 30 * 60)
            #expect(KeepAwake.shared.isActive)
            #expect(assertions()["Swivel: Keep Awake"] == kIOPMAssertionTypePreventUserIdleDisplaySleep as String)
            let remaining = KeepAwake.shared.until!.timeIntervalSinceNow
            #expect(remaining > 29 * 60 && remaining <= 30 * 60)
            #expect(KeepAwake.shared.status?.isEmpty == false)

            // Letting the display sleep swaps the assertion type and keeps the end time.
            Prefs.keepAwakeDisplay = false
            KeepAwake.shared.refreshType()
            #expect(assertions()["Swivel: Keep Awake"] == kIOPMAssertionTypePreventUserIdleSystemSleep as String)
            #expect(abs(KeepAwake.shared.until!.timeIntervalSinceNow - remaining) < 5)

            KeepAwake.shared.stop()
            #expect(!KeepAwake.shared.isActive)
            #expect(assertions()["Swivel: Keep Awake"] == nil)
            #expect(KeepAwake.shared.status == nil)
        }
    }

    @Test func untilTurnedOffAndFeatureSwitch() {
        withFeature(true) {
            KeepAwake.shared.start(for: nil)
            #expect(KeepAwake.shared.until == .distantFuture)
            #expect(KeepAwake.shared.status == L("Awake until turned off"))
            // Turning the feature off ends the session at once.
            Feature.keepAwake.isOn = false
            #expect(!KeepAwake.shared.isActive)
            #expect(assertions()["Swivel: Keep Awake"] == nil)
            // While off, nothing starts.
            KeepAwake.shared.start(for: 60)
            #expect(!KeepAwake.shared.isActive)
        }
    }

    @Test func shortSessionsEndByThemselves() async throws {
        let defaults = UserDefaults.standard, before = defaults.object(forKey: "feature.keepAwake")
        defer {
            KeepAwake.shared.stop()
            if let before { defaults.set(before, forKey: "feature.keepAwake") } else { defaults.removeObject(forKey: "feature.keepAwake") }
        }
        Prefs.setFeatureEnabled(.keepAwake, true)
        KeepAwake.shared.start(for: 0.3)
        #expect(KeepAwake.shared.isActive)
        for _ in 0..<100 where KeepAwake.shared.isActive { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!KeepAwake.shared.isActive)
        #expect(assertions()["Swivel: Keep Awake"] == nil)
    }

    @Test func quickActionsOfferKeepAwakeOnlyWhenTheFeatureIsOn() {
        withFeature(false) {
            #expect(!QuickActions.makeCommands(files: []).contains { $0.id.hasPrefix("keepAwake.") })
            Prefs.setFeatureEnabled(.keepAwake, true)
            let ids = QuickActions.makeCommands(files: []).map(\.id)
            #expect(ids.filter { $0.hasPrefix("keepAwake.") }.count == KeepAwake.durations.count)
            KeepAwake.shared.start(for: 60)
            #expect(QuickActions.makeCommands(files: []).contains { $0.id == "keepAwake.stop" })
        }
    }
}

@Suite(.serialized)
@MainActor
struct NewSettingsPagesTests {
    /// Keep Awake and the assistant section fit their pages in every language; renders on request for review.
    @Test func newPagesFitInEveryLanguage() throws {
        let defaults = UserDefaults.standard, before = defaults.object(forKey: "language")
        defer { if let before { defaults.set(before, forKey: "language") } else { defaults.removeObject(forKey: "language") } }
        let renders = ProcessInfo.processInfo.environment["SWIVEL_NEW_PAGES_RENDERS"].map { URL(fileURLWithPath: $0) }
        if let renders { try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true) }
        for language in [Language.en, .zhHans, .zhHant, .ja] {
            defaults.set(language.rawValue, forKey: "language")
            for (name, pane) in [("keepawake", KeepAwakePane() as Pane), ("quickactions", QuickActionsPane() as Pane)] {
                _ = pane.view
                pane.view.layoutSubtreeIfNeeded()
                #expect(pane.stack.fittingSize.height <= pane.preferredContentSize.height, "\(name) \(language.rawValue)")
                guard let renders else { continue }
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    pane.view.appearance = NSAppearance(named: appearance)
                    let bitmap = try #require(pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds))
                    pane.view.cacheDisplay(in: pane.view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?
                        .write(to: renders.appendingPathComponent("\(name)-\(language.rawValue)-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
        }
    }
}
