import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Swivel

/// `Swivel --mcp`: the protocol, the tool list, plans that change nothing until applied, undo, and path checks.
@Suite(.serialized)
@MainActor
struct MCPTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swivel-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolved (/var → /private/var), the way the server reports paths.
        return URL(fileURLWithPath: MCPPaths.resolved(dir), isDirectory: true)
    }

    private func png(_ url: URL, width: Int = 48, height: Int = 32) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try Images.encode(context.makeImage()!, type: .png, quality: 1).write(to: url)
    }

    /// A session whose undo log lives in `dir`, and whose undo removes files instead of using the user's Trash.
    private func session(_ dir: URL) -> MCPSession {
        let tools = MCPTools(history: MCPHistory(directory: dir.appendingPathComponent(".history")),
                             trash: { try FileManager.default.removeItem(at: $0); return nil })
        return MCPSession(tools: tools) { _ in }
    }

    /// Sends a request through JSON (as a host would) and returns the decoded answer.
    private func rpc(_ session: MCPSession, _ method: String, _ params: [String: Any]? = nil, id: Any = 1) async throws -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        let parsed = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: message)) as! [String: Any]
        let response = await session.response(to: parsed)
        // Every answer must survive the trip back to the host.
        return try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: response)) as! [String: Any]
    }

    private func initialized(_ dir: URL) async throws -> MCPSession {
        let session = self.session(dir)
        _ = try await rpc(session, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
        return session
    }

    private struct Called { let structured: [String: Any]; let isError: Bool; let text: String }

    private func call(_ session: MCPSession, _ name: String, _ arguments: [String: Any]) async throws -> Called {
        let response = try await rpc(session, "tools/call", ["name": name, "arguments": arguments])
        let result = try #require(response["result"] as? [String: Any], "\(response)")
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return Called(structured: result["structuredContent"] as? [String: Any] ?? [:], isError: result["isError"] as? Bool ?? false, text: text)
    }

    private func errorCode(_ response: [String: Any]) -> Int? { (response["error"] as? [String: Any])?["code"] as? Int }

    // MARK: Protocol

    @Test func handshakeNegotiatesTheVersionAndAnswersBothEras() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let session = self.session(dir)
        // Nothing but discovery and ping before a version is known.
        #expect(errorCode(try await rpc(session, "tools/list")) == -32602)
        #expect((try await rpc(session, "ping"))["result"] as? [String: Any] != nil)

        let hello = try #require(try await rpc(session, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                                         "clientInfo": ["name": "test", "version": "1"]])["result"] as? [String: Any])
        #expect(hello["protocolVersion"] as? String == "2025-06-18")
        #expect((hello["serverInfo"] as? [String: Any])?["name"] as? String == "swivel")
        #expect((hello["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect((hello["instructions"] as? String)?.contains("apply_plan") == true)
        let unknown = try #require(try await rpc(self.session(dir), "initialize", ["protocolVersion": "1999-01-01"])["result"] as? [String: Any])
        #expect(unknown["protocolVersion"] as? String == MCPSession.legacyVersions[0])

        let list = try #require(try await rpc(session, "tools/list")["result"] as? [String: Any])
        #expect((list["tools"] as? [Any])?.count == MCPTools.names.count)
        #expect(list["nextCursor"] == nil && list["resultType"] == nil)
        #expect(errorCode(try await rpc(session, "tools/list", ["cursor": "page2"])) == -32602)
        #expect(errorCode(try await rpc(session, "resources/list")) == -32601)
        #expect(errorCode(try await rpc(session, "tools/call", ["name": "format_disk", "arguments": [:]])) == -32602)

        // 2026-07-28: no handshake; the version travels in every request.
        let fresh = self.session(dir)
        let discover = try #require(try await rpc(fresh, "server/discover")["result"] as? [String: Any])
        #expect(discover["supportedVersions"] as? [String] == [MCPSession.modernVersion])
        #expect(discover["resultType"] as? String == "complete")
        let meta: [String: Any] = [MCPSession.versionKey: MCPSession.modernVersion, MCPSession.capabilitiesKey: [:]]
        let modern = try #require(try await rpc(fresh, "tools/list", ["_meta": meta])["result"] as? [String: Any])
        #expect(modern["resultType"] as? String == "complete" && modern["ttlMs"] != nil && modern["cacheScope"] != nil)
        #expect(errorCode(try await rpc(fresh, "tools/list", ["_meta": [MCPSession.versionKey: "2099-01-01", MCPSession.capabilitiesKey: [:]]])) == -32022)
        #expect(errorCode(try await rpc(fresh, "tools/list", ["_meta": [MCPSession.versionKey: MCPSession.modernVersion]])) == -32602)
    }

    @Test func linesThatAreNotSingleRequestsGetJSONRPCErrorsAndNotificationsGetNone() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        var sent: [[String: Any]] = []
        let session = MCPSession(tools: MCPTools(history: MCPHistory(directory: dir))) { sent.append($0) }
        session.receive(Data("{not json".utf8))
        session.receive(Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#.utf8))
        session.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        session.receive(Data(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#.utf8))
        session.receive(Data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#.utf8))
        session.receive(Data("   ".utf8))
        session.receive(Data(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#.utf8))
        #expect(sent.map(errorCode) == [-32700, -32600, -32600, nil])
        #expect(sent.last?["id"] as? String == "a")

        // A result JSON can't hold still produces exactly one line: an internal error for that request.
        let pipe = Pipe()
        MCPWriter(fd: pipe.fileHandleForWriting.fileDescriptor).write(MCPSession.success(5, ["duration": Double.nan]))
        try pipe.fileHandleForWriting.close()
        let line = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(line.last == 0x0A && line.filter { $0 == 0x0A }.count == 1)
        let decoded = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        #expect(decoded.map(errorCode) == -32603 && decoded?["id"] as? Int == 5)
    }

    @Test func toolsHaveValidNamesStrictSchemasAndHonestHints() throws {
        let tools = MCPTools.definitions
        let names = tools.compactMap { $0["name"] as? String }
        #expect(Set(names).count == names.count && names.count == 11)
        for tool in tools {
            let name = tool["name"] as! String
            #expect(name.wholeMatch(of: #/[A-Za-z0-9_.-]{1,128}/#) != nil)
            #expect((tool["description"] as? String)?.isEmpty == false)
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object" && schema["additionalProperties"] as? Bool == false)
            let hints = try #require(tool["annotations"] as? [String: Any])
            let writes = ["apply_plan", "undo"].contains(name)
            #expect(hints["readOnlyHint"] as? Bool == !writes, "\(name)")
            #expect(hints["openWorldHint"] as? Bool == false)
            #expect(try JSONSerialization.data(withJSONObject: tool).count > 0)
        }
        // The MCPB manifest lists the same tools.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("mcpb/manifest.json"))) as! [String: Any]
        #expect(Set((manifest["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }) == Set(names))
        #expect((manifest["server"] as? [String: Any])?["type"] as? String == "binary")
    }

    // MARK: Plan, apply, undo

    @Test func planChangesNothingApplyConvertsOnceAndUndoRemovesTheResult() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("photo.png")
        try png(source)
        try Data("taken".utf8).write(to: dir.appendingPathComponent("photo.jpg"))
        let session = try await initialized(dir)

        let listed = try await call(session, "list_actions", ["paths": [source.path]])
        let ids = (listed.structured["actions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        #expect(ids.contains("convert.JPG") && ids.contains("tools.Remove BG") && ids.contains("convert.PDF"))
        #expect(!ids.contains("tools.Crop") && !ids.contains("tools.Annotate"))  // Editors need a window.
        #expect(listed.structured["kind"] as? String == "image")

        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        let plan = try await call(session, "plan_action", ["action": "convert.JPG", "paths": [source.path]])
        #expect(!plan.isError, "\(plan.text)")
        let expected = dir.appendingPathComponent("photo 2.jpg").path
        #expect(plan.structured["will_create"] as? [String] == [expected])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == before)
        let planID = try #require(plan.structured["plan_id"] as? String)

        let applied = try await call(session, "apply_plan", ["plan_id": planID])
        #expect(!applied.isError, "\(applied.text)")
        #expect(applied.structured["created"] as? [String] == [expected])
        #expect(applied.structured["matches_plan"] as? Bool == true)
        let output = URL(fileURLWithPath: expected)
        let type = CGImageSourceCreateWithURL(output as CFURL, nil).flatMap(CGImageSourceGetType) as String?
        #expect(type == UTType.jpeg.identifier)
        #expect(try Data(contentsOf: dir.appendingPathComponent("photo.jpg")) == Data("taken".utf8))
        let again = try await call(session, "apply_plan", ["plan_id": planID])
        #expect(again.isError && again.text.contains("runs once"))

        let entryID = try #require(applied.structured["entry_id"] as? String)
        let history = try await call(session, "history", [:])
        let entries = try #require(history.structured["entries"] as? [[String: Any]])
        #expect(entries.first?["entry_id"] as? String == entryID && entries.first?["created"] as? [String] == [expected])

        let preview = try await call(session, "undo", ["dry_run": true])
        #expect(preview.structured["moved_to_trash"] as? [String] == [expected])
        #expect(FileManager.default.fileExists(atPath: expected))
        let undone = try await call(session, "undo", [:])
        #expect(undone.structured["entry_id"] as? String == entryID && undone.structured["moved_to_trash"] as? [String] == [expected])
        #expect(!FileManager.default.fileExists(atPath: expected))
        #expect(FileManager.default.fileExists(atPath: source.path))
        let nothing = try await call(session, "undo", [:])
        #expect(nothing.isError && nothing.text.contains("Nothing to undo"))
    }

    @Test func parallelAppliesNeverShareAnOutputName() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("photo.png")
        try png(source, width: 600, height: 400)
        var answers: [[String: Any]] = []
        let session = MCPSession(tools: MCPTools(history: MCPHistory(directory: dir.appendingPathComponent(".history")))) { answers.append($0) }
        _ = try await rpc(session, "initialize", ["protocolVersion": "2025-11-25"])
        var plans: [String] = []
        for _ in 0..<2 {
            let plan = try await call(session, "plan_action", ["action": "convert.JPG", "paths": [source.path]])
            plans.append(try #require(plan.structured["plan_id"] as? String))
        }
        // Both plans predict photo.jpg; sent together, the second must still get a name of its own.
        for (n, id) in plans.enumerated() {
            let line = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 10 + n, "method": "tools/call",
                                                                  "params": ["name": "apply_plan", "arguments": ["plan_id": id]]])
            session.receive(line)
        }
        for _ in 0..<400 where answers.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let created = answers.compactMap { (($0["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["created"] as? [String] }.flatMap { $0 }
        #expect(Set(created) == [dir.appendingPathComponent("photo.jpg").path, dir.appendingPathComponent("photo 2.jpg").path])
        for path in created {
            #expect(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap(CGImageSourceGetType) as String? == UTType.jpeg.identifier)
        }
    }

    @Test func applyRefusesInputsThatChangedAndUndoLeavesEditedOutputsAlone() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("chart.png")
        try png(source)
        let session = try await initialized(dir)
        let stale = try await call(session, "plan_action", ["action": "tools.Grayscale", "paths": [source.path]])
        try png(source, width: 64)  // Replaced after planning.
        let refused = try await call(session, "apply_plan", ["plan_id": stale.structured["plan_id"] as! String])
        #expect(refused.isError && refused.text.contains("changed since it was planned"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") } == ["chart.png"])

        let plan = try await call(session, "plan_action", ["action": "tools.Grayscale", "paths": [source.path]])
        let applied = try await call(session, "apply_plan", ["plan_id": plan.structured["plan_id"] as! String])
        let output = try #require((applied.structured["created"] as? [String])?.first)
        #expect(output.hasSuffix("chart gray.png"))
        try Data("edited by the user".utf8).write(to: URL(fileURLWithPath: output))
        let undone = try await call(session, "undo", [:])
        #expect((undone.structured["skipped"] as? [[String: Any]])?.first?["path"] as? String == output)
        #expect(FileManager.default.fileExists(atPath: output))
    }

    @Test func renamesAndMovesAreAppliedExclusivelyAndPutBackByUndo() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try "A".write(to: a, atomically: true, encoding: .utf8)
        try "B".write(to: b, atomically: true, encoding: .utf8)
        let session = try await initialized(dir)

        // A clash is reported, not planned.
        try "C".write(to: dir.appendingPathComponent("Trip-001.txt"), atomically: true, encoding: .utf8)
        let clash = try await call(session, "plan_rename", ["paths": [a.path, b.path], "base_name": "Trip", "number": true])
        #expect(clash.structured["can_apply"] as? Bool == false && clash.structured["plan_id"] == nil)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Trip-001.txt"))

        let plan = try await call(session, "plan_rename", ["paths": [a.path, b.path], "base_name": "Trip", "number": true])
        #expect(plan.structured["can_apply"] as? Bool == true)
        #expect((plan.structured["renames"] as? [[String: Any]])?.compactMap { $0["to"] as? String } ==
                [dir.appendingPathComponent("Trip-001.txt").path, dir.appendingPathComponent("Trip-002.txt").path])
        #expect(FileManager.default.fileExists(atPath: a.path))
        let renamed = try await call(session, "apply_plan", ["plan_id": plan.structured["plan_id"] as! String])
        #expect((renamed.structured["renamed"] as? [Any])?.count == 2, "\(renamed.text)")
        #expect(try String(contentsOf: dir.appendingPathComponent("Trip-002.txt"), encoding: .utf8) == "B")
        _ = try await call(session, "undo", [:])
        #expect(try String(contentsOf: a, encoding: .utf8) == "A" && (try String(contentsOf: b, encoding: .utf8)) == "B")

        let inbox = dir.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
        try "old".write(to: inbox.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let move = try await call(session, "plan_move", ["paths": [a.path], "destination": inbox.path])
        #expect((move.structured["moves"] as? [[String: Any]])?.first?["to"] as? String == inbox.appendingPathComponent("a 2.txt").path)
        let moved = try await call(session, "apply_plan", ["plan_id": move.structured["plan_id"] as! String])
        #expect(!moved.isError, "\(moved.text)")
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(try String(contentsOf: inbox.appendingPathComponent("a.txt"), encoding: .utf8) == "old")
        let back = try await call(session, "undo", [:])
        #expect((back.structured["restored"] as? [Any])?.count == 1)
        #expect(try String(contentsOf: a, encoding: .utf8) == "A")
        let intoItself = try await call(session, "plan_move", ["paths": [inbox.path], "destination": inbox.path])
        #expect(intoItself.structured["can_apply"] as? Bool == false)
    }

    @Test func undoLeavesACreatedFolderAloneWhenAnythingInsideItChanged() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let pack = dir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: pack.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try "first".write(to: pack.appendingPathComponent("inner/note.txt"), atomically: false, encoding: .utf8)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", "--", pack.path, dir.appendingPathComponent("pack.zip").path]
        try zip.run(); zip.waitUntilExit()
        try FileManager.default.removeItem(at: pack)
        let session = try await initialized(dir)

        let plan = try await call(session, "plan_action", ["action": "convert.Extract", "paths": [dir.appendingPathComponent("pack.zip").path]])
        let applied = try await call(session, "apply_plan", ["plan_id": try #require(plan.structured["plan_id"] as? String, "\(plan.text)")])
        #expect(applied.structured["created"] as? [String] == [pack.path], "\(applied.text)")
        // Edited in place, two levels down: the folder's own entry (size, date) stays exactly as it was.
        let folderBefore = try MCPFingerprint.read(pack)
        try "edited".write(to: pack.appendingPathComponent("inner/note.txt"), atomically: false, encoding: .utf8)
        #expect(try MCPFingerprint.read(pack) == folderBefore)

        let undone = try await call(session, "undo", [:])
        #expect((undone.structured["skipped"] as? [[String: Any]])?.first?["path"] as? String == pack.path, "\(undone.text)")
        #expect(undone.structured["complete"] as? Bool == false)
        #expect(try String(contentsOf: pack.appendingPathComponent("inner/note.txt"), encoding: .utf8) == "edited")

        // Too many entries to check counts as changed.
        let tree = try MCPFingerprint.read(pack, withContents: true)
        #expect(tree.tree != nil && tree.tree != MCPFingerprint.unchecked && tree.isCurrent())
        #expect(MCPFingerprint.digest(pack.path, limit: 1) == MCPFingerprint.unchecked)
        var unchecked = tree; unchecked.tree = MCPFingerprint.unchecked
        #expect(!unchecked.isCurrent())
    }

    @Test func anUndoThatSkipsSomethingStaysOpenAndRetriesOnlyWhatIsLeft() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try "A".write(to: a, atomically: true, encoding: .utf8)
        try "B".write(to: b, atomically: true, encoding: .utf8)
        let inbox = dir.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
        let session = try await initialized(dir)
        let move = try await call(session, "plan_move", ["paths": [a.path, b.path], "destination": inbox.path])
        let moved = try await call(session, "apply_plan", ["plan_id": try #require(move.structured["plan_id"] as? String)])
        let entryID = try #require(moved.structured["entry_id"] as? String)

        try "blocker".write(to: a, atomically: true, encoding: .utf8)  // a.txt can't go back yet.
        let first = try await call(session, "undo", [:])
        #expect(first.structured["complete"] as? Bool == false)
        #expect((first.structured["restored"] as? [[String: Any]])?.compactMap { $0["to"] as? String } == [b.path])
        #expect((first.structured["skipped"] as? [[String: Any]])?.first?["path"] as? String == inbox.appendingPathComponent("a.txt").path)
        let open = try #require((try await call(session, "history", [:])).structured["entries"] as? [[String: Any]]).first
        #expect(open?["undone"] == nil && (open?["moves"] as? [Any])?.count == 1)

        try FileManager.default.removeItem(at: a)
        let retry = try await call(session, "undo", [:])
        #expect(retry.structured["entry_id"] as? String == entryID && retry.structured["complete"] as? Bool == true, "\(retry.text)")
        #expect((retry.structured["restored"] as? [[String: Any]])?.compactMap { $0["to"] as? String } == [a.path])
        #expect(try String(contentsOf: a, encoding: .utf8) == "A" && (try String(contentsOf: b, encoding: .utf8)) == "B")
        #expect(try await call(session, "undo", [:]).text.contains("Nothing to undo"))
    }

    @Test func aMoveIsRefusedWhenItsDestinationWasReplacedOrBecameALink() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        try "A".write(to: a, atomically: true, encoding: .utf8)
        let inbox = dir.appendingPathComponent("Inbox"), elsewhere = dir.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        let session = try await initialized(dir)

        for swap in [
            { try FileManager.default.moveItem(at: inbox, to: dir.appendingPathComponent("Inbox old"))
              try FileManager.default.createSymbolicLink(at: inbox, withDestinationURL: elsewhere) },
            { try FileManager.default.removeItem(at: inbox)
              try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false) },
        ] as [() throws -> Void] {
            try? FileManager.default.removeItem(at: inbox)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("Inbox old"))
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
            let plan = try await call(session, "plan_move", ["paths": [a.path], "destination": inbox.path])
            try swap()
            let refused = try await call(session, "apply_plan", ["plan_id": try #require(plan.structured["plan_id"] as? String)])
            #expect(refused.isError && refused.text.contains("destination"), "\(refused.text)")
            #expect(FileManager.default.fileExists(atPath: a.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        }
    }

    @Test func foldersAboveTheUndoLogAndHardLinksToItAreRefused() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let session = try await initialized(dir)  // Its undo log is dir/.history.
        let history = dir.appendingPathComponent(".history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: history.appendingPathComponent("history.json"))
        let link = dir.appendingPathComponent("notes.json")
        try FileManager.default.linkItem(at: history.appendingPathComponent("history.json"), to: link)
        let target = try folder(); defer { try? FileManager.default.removeItem(at: target) }

        var above = [dir.path, dir.deletingLastPathComponent().path]
        // The same folder spelled in another case, on a disk that doesn't tell them apart.
        let shouted = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent.uppercased()).path
        if FileManager.default.fileExists(atPath: shouted) { above.append(shouted) }
        for path in above + [link.path] {
            for (tool, arguments) in [("plan_rename", ["paths": [path], "prefix": "x "]), ("plan_move", ["paths": [path], "destination": target.path]),
                                      ("plan_action", ["paths": [path], "action": "tools.ZIP"])] as [(String, [String: Any])] {
                let result = try await call(session, tool, arguments)
                #expect(result.isError && result.text.contains("undo log"), "\(tool) \(path): \(result.text)")
            }
        }
        // Moving something into a folder above the log leaves the log where it is.
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try "x".write(to: sub.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        #expect(try await call(session, "plan_move", ["paths": [sub.appendingPathComponent("x.txt").path], "destination": dir.path]).structured["can_apply"] as? Bool == true)
        #expect(try await call(session, "plan_move", ["paths": [sub.appendingPathComponent("x.txt").path], "destination": history.path]).text.contains("undo log"))
    }

    @Test func anUndoLogThatCantBeOpenedIsNeverWrittenOver() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let history = dir.appendingPathComponent(".history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let log = history.appendingPathComponent("history.json")
        try Data("[]".utf8).write(to: log)
        chmod(log.path, 0)
        defer { chmod(log.path, 0o600) }
        let session = try await initialized(dir)
        let listed = try await call(session, "history", [:])
        #expect(listed.isError && listed.text.contains("Couldn't read"), "\(listed.text)")
        // An apply that couldn't be logged for undo changes nothing.
        let image = dir.appendingPathComponent("p.png")
        try png(image)
        let plan = try await call(session, "plan_action", ["action": "convert.JPG", "paths": [image.path]])
        let id = try #require(plan.structured["plan_id"] as? String)
        let applied = try await call(session, "apply_plan", ["plan_id": id])
        #expect(applied.isError && applied.text.contains("Nothing was changed"), "\(applied.text)")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("p.jpg").path))
    }

    @Test func anUnreadableUndoLogIsSetAsideAndReported() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let history = dir.appendingPathComponent(".history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: history.appendingPathComponent("history.json"))
        let session = try await initialized(dir)
        let listed = try await call(session, "history", [:])
        #expect((listed.structured["warning"] as? String)?.contains("set aside") == true, "\(listed.text)")
        let undo = try await call(session, "undo", [:])
        #expect(undo.isError && undo.text.contains("set aside"), "\(undo.text)")
    }

    @Test func trailingSlashesOnFilesAndInvisibleCharactersInNewNamesAreRefused() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.png")
        try png(real)
        let session = try await initialized(dir)
        let slash = try await call(session, "plan_action", ["action": "convert.JPG", "paths": [real.path + "/"]])
        #expect(slash.isError && slash.text.contains("ends in /"), "\(slash.text)")
        // A folder may still be written with one (and its ZIP keeps the id it had under Convert).
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        #expect(!(try await call(session, "plan_action", ["action": "convert.ZIP", "paths": [sub.path + "/"]]).isError))

        for hidden in ["\u{202E}gnp", "\u{2066}x", "a\u{200B}b", "\u{FEFF}", "a\u{202A}"] {
            let plan = try await call(session, "plan_rename", ["paths": [real.path], "base_name": "photo" + hidden])
            #expect(plan.structured["can_apply"] as? Bool == false && plan.structured["plan_id"] == nil, "\(hidden.unicodeScalars.map(\.value))")
        }
        // Emoji sequences keep their joiners.
        #expect(try await call(session, "plan_rename", ["paths": [real.path], "base_name": "family \u{1F468}\u{200D}\u{1F469}"]).structured["can_apply"] as? Bool == true)

        // Long values from the host are cut short in errors.
        let long = String(repeating: "x", count: 5_000)
        let refused = try await call(session, "plan_action", ["action": "convert.JPG", "paths": [long]])
        #expect(refused.isError && refused.text.count < 600 && refused.text.contains("…"))
    }

    // MARK: Framing

    @Test func aLineOverTheLimitIsDroppedAsItArrivesAndAnsweredOnce() throws {
        var reader = MCPLineReader()
        var lines: [MCPLineReader.Line] = []
        let megabyte = [UInt8](repeating: 0x61, count: 1 << 20)
        for _ in 0..<40 {  // 40 MB without a newline
            lines += reader.feed(megabyte)
            #expect(reader.buffer.count <= MCPLineReader.limit)
        }
        lines += reader.feed(Data("tail\n{\"a\":1}\r\npartial".utf8))
        lines += reader.finish()
        #expect(lines == [.tooLong, .message(Data(#"{"a":1}"#.utf8)), .message(Data("partial".utf8))])

        var sent: [[String: Any]] = []
        let session = MCPSession(tools: MCPTools(history: MCPHistory(directory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString)")))) { sent.append($0) }
        session.receiveTooLong()
        #expect(sent.first.map(errorCode) == -32600 && sent.first?["id"] is NSNull)
    }

    @Test func aReusedRequestIdIsAnsweredAfterTheCallInFlightAndNeverRun() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        var sent: [[String: Any]] = []
        let session = MCPSession(tools: MCPTools(history: MCPHistory(directory: dir.appendingPathComponent(".history")))) { sent.append($0) }
        _ = try await rpc(session, "initialize", ["protocolVersion": "2025-11-25"])
        session.receive(Data(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"history","arguments":{}}}"#.utf8))
        session.receive(Data(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"undo","arguments":{}}}"#.utf8))
        for _ in 0..<400 where sent.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sent.count == 2)
        // The first answer with id 5 is the original's; the duplicate's refusal follows.
        #expect(sent.first?["result"] != nil && sent.first?["id"] as? Int == 5)
        #expect(sent.last.map(errorCode) == -32600 && sent.last?["id"] as? Int == 5)
    }

    // MARK: Paths

    @Test func badPathsAndArgumentsAreRejectedWithoutTouchingAnything() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.png")
        try png(real)
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let dangling = dir.appendingPathComponent("dangling.png")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: dir.appendingPathComponent("nowhere.png"))
        let fifo = dir.appendingPathComponent("pipe.png")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let session = try await initialized(dir)
        let history = dir.appendingPathComponent(".history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let bad: [(Any, String)] = [
            ("real.png", "absolute"), ("~/real.png", "absolute"), (dir.path + "/../" + dir.lastPathComponent + "/real.png", "plain"),
            (dir.path + "/./real.png", "plain"), (dir.path + "//real.png", "plain"), (link.path, "symbolic link"),
            (dangling.path, "symbolic link"), (fifo.path, "regular file"), ("/dev/null", "regular file"),
            (dir.appendingPathComponent("missing.png").path, "doesn't exist"), (history.path, "undo log"),
            ("/", "plain"), (42, "strings"),
        ]
        for (path, reason) in bad {
            let result = try await call(session, "plan_action", ["action": "convert.JPG", "paths": [path]])
            #expect(result.isError && result.text.contains(reason), "\(path): \(result.text)")
        }
        for arguments: [String: Any] in [["action": "convert.JPG", "paths": []], ["action": "convert.JPG"],
                                         ["action": "convert.JPG", "paths": [real.path], "overwrite": true],
                                         ["action": "tools.Crop", "paths": [real.path]]] {
            #expect(try await call(session, "plan_action", arguments).isError, "\(arguments)")
        }
        #expect(try await call(session, "plan_move", ["paths": [real.path], "destination": real.path]).text.contains("not a folder"))
        #expect(try await call(session, "plan_compress", ["paths": [real.path], "target_bytes": 10]).isError)
        #expect(try await call(session, "plan_rename", ["paths": [real.path]]).isError)
        #expect(try await call(session, "plan_rename", ["paths": [real.path], "base_name": "../escape"]).structured["can_apply"] as? Bool == false)
        #expect(try await call(session, "apply_plan", ["plan_id": "made-up"]).isError)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == before)

        // Ancestor links (/var → /private/var) are fine; the result is the resolved path of the same file.
        let viaVar = FileManager.default.temporaryDirectory.appendingPathComponent("swivel-mcp-var-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: viaVar) }
        try png(viaVar)
        #expect(viaVar.path.hasPrefix("/var/") || viaVar.path.hasPrefix("/tmp/") || viaVar.path.hasPrefix("/private/"))
        #expect(try MCPPaths.entry(viaVar.path).path == MCPPaths.resolved(viaVar))
        #expect(try MCPPaths.entry(viaVar.path).path.hasPrefix("/private/"))
    }

    // MARK: Settings

    @Test func setupSectionFitsTheGeneralPageAndCopiesWorkingConfigs() throws {
        let defaults = UserDefaults.standard, before = defaults.object(forKey: "language")
        defer { if let before { defaults.set(before, forKey: "language") } else { defaults.removeObject(forKey: "language") } }
        let renders = ProcessInfo.processInfo.environment["SWIVEL_MCP_RENDERS"].map { URL(fileURLWithPath: $0) }
        if let renders { try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true) }
        for language in [Language.en, .zhHans, .zhHant, .ja] {
            defaults.set(language.rawValue, forKey: "language")
            let pane = GeneralPane()
            _ = pane.view
            // With the longest status showing (Claude Desktop's fallback, three lines in some languages).
            func setup(in view: NSView) -> MCPSetupView? { view as? MCPSetupView ?? view.subviews.lazy.compactMap(setup).first }
            let setupView = try #require(setup(in: pane.view))
            setupView.status.stringValue = L("Copied. Quit Claude first (a running Claude rewrites its config file), then add the “swivel” entry to “mcpServers” in claude_desktop_config.json and open Claude again.")
            pane.view.layoutSubtreeIfNeeded()
            #expect(pane.stack.fittingSize.height <= pane.preferredContentSize.height, "\(language.rawValue)")
            #expect(pane.stack.fittingSize.width <= pane.preferredContentSize.width, "\(language.rawValue)")
            guard let renders else { continue }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                pane.view.appearance = NSAppearance(named: appearance)
                let bitmap = try #require(pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds))
                pane.view.cacheDisplay(in: pane.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: renders.appendingPathComponent("general-\(language.rawValue)-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
        for key in ["Agents", "Install in Claude Desktop", "Copy Claude Code Setup", "Copy Codex Setup"] { #expect(Strings.table[key]?.count == 3) }

        let view = MCPSetupView()
        view.pasteboard = NSPasteboard(name: .init("swivel-mcp-test-\(UUID().uuidString)"))
        defer { view.pasteboard.releaseGlobally() }
        let marker = "untouched-\(UUID().uuidString)"

        // Claude Desktop installed and the extension bundled: Claude opens the .mcpb (its own installer persists it).
        var opened: [(URL, URL)] = []
        let claudeApp = URL(fileURLWithPath: "/Applications/Claude.app"), mcpb = URL(fileURLWithPath: "/tmp/Swivel.mcpb")
        view.claudeApp = { claudeApp }
        view.bundledExtension = { mcpb }
        view.openWithApp = { opened.append(($0, $1)) }
        view.pasteboard.clearContents(); view.pasteboard.setString(marker, forType: .string)
        view.installClaude()
        if MCPSetupView.launcherFindsSwivel() {
            #expect(opened.count == 1 && opened.first?.0 == mcpb && opened.first?.1 == claudeApp)
            #expect(view.pasteboard.string(forType: .string) == marker)
            #expect(!view.status.stringValue.isEmpty)
        }

        // No Claude.app (or no bundled extension): the JSON, with the note to quit Claude first.
        for (app, file) in [(nil, mcpb), (claudeApp, nil)] as [(URL?, URL?)] {
            opened = []
            view.claudeApp = { app }
            view.bundledExtension = { file }
            view.status.stringValue = ""
            view.installClaude()
            #expect(opened.isEmpty)
            let claude = try JSONSerialization.jsonObject(with: Data(try #require(view.pasteboard.string(forType: .string)).utf8)) as? [String: Any]
            let server = (claude?["mcpServers"] as? [String: Any])?["swivel"] as? [String: Any]
            #expect(server?["command"] as? String == MCPSetupView.command && server?["args"] as? [String] == ["--mcp"])
            #expect(view.status.stringValue.contains("claude_desktop_config.json"))
        }
        #expect(!MCPSetupView.launcherFindsSwivel(in: ["/nonexistent/Swivel.app"]))

        view.copyClaudeCode()
        #expect(view.pasteboard.string(forType: .string) == "claude mcp add --scope user swivel -- \(MCPSetupView.shellQuoted(MCPSetupView.command)) --mcp")
        #expect(MCPSetupView.claudeCodeCommand(command: "/Applications/Swivel.app/Contents/MacOS/Swivel")
            == "claude mcp add --scope user swivel -- /Applications/Swivel.app/Contents/MacOS/Swivel --mcp")
        #expect(MCPSetupView.claudeCodeCommand(command: "/Users/a b/it's/Swivel")
            == #"claude mcp add --scope user swivel -- '/Users/a b/it'\''s/Swivel' --mcp"#)
        view.copyCodex()
        #expect(view.pasteboard.string(forType: .string)?.hasPrefix("[mcp_servers.swivel]\ncommand = \"") == true)
        #expect(MCPSetupView.codexConfig(command: #"/A "b"\c"#).contains(#"command = "/A \"b\"\\c""#))
    }

    @Test func theExtensionPacksTheCheckedInManifestAndLauncher() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let packed = dir.appendingPathComponent("Swivel.mcpb")
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/bin/bash")
        pack.arguments = [root.appendingPathComponent("mcpb/pack.sh").path, packed.path]
        pack.standardOutput = FileHandle.nullDevice
        try pack.run(); pack.waitUntilExit()
        #expect(pack.terminationStatus == 0)

        func unzip(_ arguments: String...) throws -> Data {
            let process = Process(), out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = arguments
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }
        let manifest = try Data(contentsOf: root.appendingPathComponent("mcpb/manifest.json"))
        let launcher = try Data(contentsOf: root.appendingPathComponent("mcpb/server/swivel-mcp"))
        // Built app (./build.sh) too, when there is one: it must carry the same manifest.
        let built = root.appendingPathComponent("build/Swivel.app/Contents/Resources/Swivel.mcpb")
        for archive in [packed] + (FileManager.default.fileExists(atPath: built.path) ? [built] : []) {
            let names = Set(String(decoding: try unzip("-Z1", archive.path), as: UTF8.self).split(separator: "\n").map(String.init))
            #expect(names.isSuperset(of: ["manifest.json", "icon.png", "server/swivel-mcp"]), "\(archive.path)")
            #expect(try unzip("-p", archive.path, "manifest.json") == manifest, "\(archive.path)")
            #expect(try unzip("-p", archive.path, "server/swivel-mcp") == launcher, "\(archive.path)")
            let mode = String(decoding: try unzip("-Z", archive.path), as: UTF8.self)
                .split(separator: "\n").first { $0.hasSuffix("server/swivel-mcp") }
            #expect(mode?.hasPrefix("-rwxr-xr-x") == true, "\(archive.path)")
        }

        // The extension's version follows the app's, and its launcher looks where the setup page checks.
        let json = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        let plist = try #require(NSDictionary(contentsOf: root.appendingPathComponent("Resources/Info.plist")))
        #expect(json["version"] as? String == plist["CFBundleShortVersionString"] as? String)
        let script = String(decoding: launcher, as: UTF8.self)
        for location in MCPSetupView.launcherLocations {
            let written = location.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME")
            #expect(script.contains("\"\(written)\""), "\(written)")
        }
    }

    // MARK: The process

    @Test func theServerProcessTalksOnlyOverStdioAndListensOnNoPort() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/debug/Swivel")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "build the debug binary first (./test.sh does)")
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("photo.png")
        try png(source)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--mcp"]
        process.environment = ["SWIVEL_MCP_HISTORY_DIR": dir.appendingPathComponent(".history").path, "HOME": NSHomeDirectory()]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let lines = LineCollector()
        output.fileHandleForReading.readabilityHandler = { lines.append($0.availableData) }
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        func send(_ text: String) { input.fileHandleForWriting.write(Data((text + "\n").utf8)) }
        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let list = try await lines.answer(2)
        #expect(((list["result"] as? [String: Any])?["tools"] as? [Any])?.count == MCPTools.names.count)
        send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"plan_action","arguments":{"action":"convert.JPG","paths":["\#(source.path)"]}}}"#)
        let plan = try await lines.answer(3)
        let planID = try #require(((plan["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["plan_id"] as? String)
        // Every line on stdout was a protocol message: the collector parsed them all.
        #expect(lines.unparsed == 0)

        // No internet sockets of any kind, listening or not.
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-p", String(process.processIdentifier), "-i"]
        let sockets = Pipe()
        lsof.standardOutput = sockets
        lsof.standardError = FileHandle.nullDevice
        try lsof.run()
        lsof.waitUntilExit()
        #expect(String(decoding: sockets.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).isEmpty)

        // Not an app instance to Launch Services: with one checked in, `open Swivel.app` (Finder, Dock, login items)
        // would only activate this child while a host keeps it running, and the menu-bar app would never start.
        #expect(NSRunningApplication(processIdentifier: process.processIdentifier) == nil)

        // Closing stdin ends the session once the conversion in flight has answered.
        send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"apply_plan","arguments":{"plan_id":"\#(planID)"}}}"#)
        try input.fileHandleForWriting.close()
        let applied = try await lines.answer(4)
        #expect(((applied["result"] as? [String: Any])?["isError"] as? Bool) == false)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("photo.jpg").path))
        for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!process.isRunning && process.terminationStatus == 0)
        #expect(lines.unparsed == 0)

        // And the code has no way to open one.
        for file in ["MCPServer.swift", "MCPTools.swift"] {
            let code = try String(contentsOf: root.appendingPathComponent("Sources/Swivel/\(file)"), encoding: .utf8)
            for call in ["socket(", "bind(", "listen(", "NWListener", "import Network", "URLSession", "CFSocket"] {
                #expect(!code.contains(call), "\(file) uses \(call)")
            }
        }
    }

    /// PDFKit creates an NSApplication behind the scenes, which checks the process in with Launch Services. Done as
    /// Swivel.app, `open Swivel.app` then failed with -600 for as long as Claude Desktop kept a server that had once
    /// made a PDF. In an app bundle, `Swivel --mcp` execs the background-only helper, so whatever checks in is the
    /// helper, under its own identifier.
    @Test func inAnAppBundleTheServerRunsAsTheBackgroundHelper() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/debug/Swivel")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "build the debug binary first (./test.sh does)")
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        // A miniature of build.sh's layout, with identifiers of its own.
        let app = dir.appendingPathComponent("Swivel.app"), id = "local.swivel.helpertest"
        let helper = app.appendingPathComponent("Contents/Helpers/Swivel MCP.app")
        for (bundle, info) in [(app, ["CFBundleIdentifier": id, "CFBundleExecutable": "Swivel", "CFBundlePackageType": "APPL", "LSUIElement": true] as [String: Any]),
                               (helper, ["CFBundleIdentifier": id + ".mcp", "CFBundleExecutable": "Swivel", "CFBundlePackageType": "APPL",
                                         "LSBackgroundOnly": true, MCPStdio.appIdentifierKey: id])] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: binary, to: bundle.appendingPathComponent("Contents/MacOS/Swivel"))
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        let main = app.appendingPathComponent("Contents/MacOS/Swivel")
        #expect(MCPStdio.helperExecutable(besides: main).standardizedFileURL == helper.appendingPathComponent("Contents/MacOS/Swivel").standardizedFileURL)
        let source = dir.appendingPathComponent("photo.png")
        try png(source)

        let process = Process()
        process.executableURL = main
        process.arguments = ["--mcp"]
        process.environment = ["HOME": NSHomeDirectory()]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let lines = LineCollector()
        output.fileHandleForReading.readabilityHandler = { lines.append($0.availableData) }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        func send(_ text: String) { input.fileHandleForWriting.write(Data((text + "\n").utf8)) }
        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        _ = try await lines.answer(1)

        // Same pid, the helper's executable.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        #expect(proc_pidpath(process.processIdentifier, &path, UInt32(path.count)) > 0)
        #expect(URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
                == helper.appendingPathComponent("Contents/MacOS/Swivel").resolvingSymlinksInPath().path)

        // A PDF is what checked the server in; it may still, but never as the app.
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"plan_action","arguments":{"action":"tools.Make PDF","paths":["\#(source.path)"]}}}"#)
        let plan = try await lines.answer(2)
        let planID = try #require(((plan["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["plan_id"] as? String)
        send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"apply_plan","arguments":{"plan_id":"\#(planID)"}}}"#)
        let applied = try await lines.answer(3)
        #expect(((applied["result"] as? [String: Any])?["isError"] as? Bool) == false)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("photo.pdf").path))
        try await Task.sleep(for: .milliseconds(300))
        if let checkedIn = NSRunningApplication(processIdentifier: process.processIdentifier) {
            #expect(checkedIn.bundleIdentifier == id + ".mcp")
            #expect(checkedIn.activationPolicy == .prohibited)
        }
        #expect(NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty)
        try input.fileHandleForWriting.close()
        for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!process.isRunning && process.terminationStatus == 0)

        // The helper serves nothing else: no menu-bar app, no developer modes.
        for arguments in [[String](), ["--tool", "shelf"], ["--run", "convert", "JPG", source.path]] {
            let other = Process()
            other.executableURL = helper.appendingPathComponent("Contents/MacOS/Swivel")
            other.arguments = arguments
            other.standardOutput = FileHandle.nullDevice
            other.standardError = FileHandle.nullDevice
            try other.run()
            for _ in 0..<100 where other.isRunning { try await Task.sleep(for: .milliseconds(50)) }
            if other.isRunning { other.terminate() }
            #expect(other.terminationStatus == 64, "\(arguments)")
        }

        // build.sh ships it that way.
        let build = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        for piece in ["Contents/Helpers/Swivel MCP.app", "LSBackgroundOnly bool true", "SwivelAppIdentifier string", "$APP_ID.mcp"] {
            #expect(build.contains(piece), "\(piece)")
        }
    }
}

/// Collects a child's stdout and hands out the JSON-RPC answer with a given id.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var messages: [[String: Any]] = []
    private(set) var unparsed = 0

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { messages.append(message) } else { unparsed += 1 }
        }
    }

    func answer(_ id: Int, timeout: Double = 30) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found: [String: Any]? = lock.withLock { messages.first { ($0["id"] as? Int) == id } }
            if let found { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ToolError("No answer to request \(id)")
    }
}
