import Foundation
import Testing
@testable import Swivel

@Suite(.serialized)
@MainActor
struct ScreenshotSessionTests {
    @Test func processLeaseRejectsASecondOwnerAndCanBeReacquiredAfterRelease() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwivelLease-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("instance.lock")
        let first = AppInstanceLease(file: file), second = AppInstanceLease(file: file)
        #expect(try first.acquire()); #expect(try first.acquire())
        #expect(try !second.acquire())
        first.release()
        #expect(try second.acquire())
        #expect(try !first.acquire())
        second.release()
        #expect(try first.acquire()); first.release()
    }

    @MainActor private final class SystemValues {
        var values: [String: Any] = [:]
        var writes: [String] = []
        func session(_ defaults: UserDefaults, owner: String = "owner") -> ScreenshotSession {
            ScreenshotSession(defaults: defaults, owner: owner, read: { self.values[$0] }, write: { key, value in
                self.writes.append(key); self.values[key] = value
            }, synchronize: {})
        }
    }
    private let incoming = URL(fileURLWithPath: "/temporary/Swivel/Incoming", isDirectory: true)
    private func preferences() -> (String, UserDefaults) {
        let name = "SwivelScreenshotTests-" + UUID().uuidString
        return (name, UserDefaults(suiteName: name)!)
    }

    @Test func unsetSystemPreferencesAreRestoredAndHealthyRechecksDoNotWrite() {
        let (name, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let system = SystemValues(), session = system.session(defaults)
        session.enable(into: incoming)
        #expect(session.isActive(into: incoming))
        session.enable(into: incoming)
        #expect(system.writes.count == 2)
        #expect(session.restore())
        #expect(system.values.isEmpty)
        #expect(defaults.dictionary(forKey: ScreenshotSession.savedKey) == nil)
        #expect(defaults.string(forKey: ScreenshotSession.ownerKey) == nil)
        #expect(!session.restore())
    }

    @Test func quittingAnOlderCopyCannotUndoTheCurrentOwnersTakeover() {
        let (name, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let system = SystemValues()
        system.values = ["location": "/original/screenshots", "show-thumbnail": true]
        let first = system.session(defaults, owner: "Applications"), second = system.session(defaults, owner: "Desktop")
        first.enable(into: incoming); second.enable(into: incoming)
        #expect(!first.restore())
        #expect(second.isActive(into: incoming))
        #expect(second.originalLocation.path == "/original/screenshots")
        #expect(second.restore())
        #expect(system.values["location"] as? String == "/original/screenshots")
        #expect(system.values["show-thumbnail"] as? Bool == true)
    }

    @Test func restartAdoptsALegacyBackupWithoutSavingIncomingAsTheOriginal() {
        let (name, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["location": "/before/update", "show-thumbnail": true], forKey: ScreenshotSession.savedKey)
        let system = SystemValues(); system.values = ["location": incoming.path, "show-thumbnail": false]
        let session = system.session(defaults)
        session.enable(into: incoming)
        #expect(session.originalLocation.path == "/before/update")
        #expect(session.restore())
        #expect(system.values["location"] as? String == "/before/update")
        #expect(system.values["show-thumbnail"] as? Bool == true)
    }

    @Test func recheckingRepairsLostSettingsAndRecoversAnAbandonedIncomingDestination() {
        let (name, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let system = SystemValues(), session = system.session(defaults)
        session.enable(into: incoming)
        system.values = [:] // Another old process restored the system's original settings.
        defaults.removeObject(forKey: ScreenshotSession.savedKey)
        session.enable(into: incoming)
        #expect(session.isActive(into: incoming)); #expect(session.restore()); #expect(system.values.isEmpty)
        system.values = ["location": incoming.path, "show-thumbnail": false]
        session.enable(into: incoming)
        #expect(session.originalLocation.lastPathComponent == "Desktop")
        #expect(session.restore()); #expect(system.values.isEmpty)
    }

    @Test func quittingPreservesAnExternalChangeToTheScreenshotDestination() {
        let (name, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let system = SystemValues(); system.values = ["location": "/original", "show-thumbnail": true]
        let session = system.session(defaults); session.enable(into: incoming)
        system.values = ["location": "/chosen/in/system/toolbar", "show-thumbnail": true]
        #expect(session.restore())
        #expect(system.values["location"] as? String == "/chosen/in/system/toolbar")
        #expect(system.values["show-thumbnail"] as? Bool == true)
        session.enable(into: incoming)
        system.values = ["location": "/another/chosen/folder", "show-thumbnail": true]
        session.enable(into: incoming) // App activation repairs takeover and retains the new restore choice.
        #expect(session.isActive(into: incoming)); #expect(session.restore())
        #expect(system.values["location"] as? String == "/another/chosen/folder")
        #expect(system.values["show-thumbnail"] as? Bool == true)
    }

    @Test func duplicateLaunchesAlwaysChooseTheOldestProcessIndependentOfListOrder() {
        let earlier = AppInstance.Process(pid: 200, launched: Date(timeIntervalSince1970: 10))
        let later = AppInstance.Process(pid: 100, launched: Date(timeIntervalSince1970: 20))
        #expect(AppInstance.leader([earlier, later]) == 200)
        #expect(AppInstance.leader([later, earlier]) == 200)
        #expect(AppInstance.leader([.init(pid: 201, launched: earlier.launched), earlier]) == 200)
        #expect(AppInstance.leader([]) == nil)
    }
}
