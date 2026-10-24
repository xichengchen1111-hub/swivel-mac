import Foundation
import Testing
@testable import Swivel

/// Answers every request with a canned reply and records what was sent. No network is used.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (Int, Data) = (200, Data())
    nonisolated(unsafe) static var sent: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            request.httpBody = body
        }
        Self.sent.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
@MainActor
struct AssistantTests {
    @Test func oversizedRepliesAreStoppedWithoutNetwork() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let old = StubProtocol.reply
        defer { StubProtocol.reply = old }
        StubProtocol.reply = (200, Data(repeating: 65, count: 2 * 1024 * 1024 + 1))
        await #expect(throws: (any Error).self) {
            try await Assistant.send(URLRequest(url: URL(string: "https://fixture.invalid/reply")!), using: session)
        }
    }
    private let choices = [Assistant.Choice(id: "tools.Compress", title: "Compress", group: "Tools"),
                           Assistant.Choice(id: "convert.PDF", title: "PDF", group: "Convert")]
    private let files = [URL(fileURLWithPath: "/Users/me/Secret Project/passport scan.jpg"),
                         URL(fileURLWithPath: "/Users/me/Secret Project/contract.pdf")]

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func claudeRequestsCarryTheToolAndNoFileNames() throws {
        let settings = Assistant.Settings.standard
        let request = try Assistant.makeRequest(settings, key: "sk-test", request: "make these smaller",
                                                choices: choices, files: Assistant.summary(of: files))
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let json = try body(request)
        #expect(json["model"] as? String == "claude-opus-5-5")
        #expect(json["fallbacks"] as? String == "default")
        #expect((json["tool_choice"] as? [String: Any])?["type"] as? String == "auto")
        let tool = try #require((json["tools"] as? [[String: Any]])?.first)
        #expect(tool["strict"] as? Bool == true)
        let schema = try #require(tool["input_schema"] as? [String: Any])
        let actionEnum = ((schema["properties"] as? [String: Any])?["action_id"] as? [String: Any])?["enum"] as? [String]
        #expect(actionEnum == ["tools.Compress", "convert.PDF"])
        let text = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(!text.contains("passport") && !text.contains("Secret Project") && !text.contains("contract"))
        #expect(text.contains("jpg") && text.contains("pdf"))
    }

    @Test func compatibleRequestsUseChatCompletionsAndKeysOnlyOverHttps() throws {
        var settings = Assistant.Settings(provider: .openAICompatible, baseURL: "https://api.deepseek.com/", model: "deepseek-chat")
        let request = try Assistant.makeRequest(settings, key: "sk-x", request: "pdf please", choices: choices, files: "1 file")
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
        let tools = try #require(try body(request)["tools"] as? [[String: Any]])
        #expect((tools.first?["function"] as? [String: Any])?["name"] as? String == Assistant.toolName)

        settings.baseURL = "http://example.com/v1"
        #expect(throws: (any Error).self) { try Assistant.makeRequest(settings, key: "sk-x", request: "x", choices: choices, files: "") }
        settings.baseURL = "http://localhost:11434/v1"
        let local = try Assistant.makeRequest(settings, key: nil, request: "x", choices: choices, files: "")
        #expect(local.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(local.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test func repliesOnlySelectOfferedActions() throws {
        let allowed = Set(choices.map(\.id))
        let claude = #"{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"choose_action","input":{"action_id":"tools.Compress","explanation":"Compresses both images."}}]}"#
        #expect(try Assistant.parse(Data(claude.utf8), provider: .anthropic, allowed: allowed)
                == .init(actionID: "tools.Compress", message: "Compresses both images."))
        let invented = #"{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"choose_action","input":{"action_id":"actions.Delete Everything","explanation":"x"}}]}"#
        #expect(try Assistant.parse(Data(invented.utf8), provider: .anthropic, allowed: allowed).actionID == nil)
        let refusal = #"{"stop_reason":"refusal","content":[]}"#
        #expect(throws: (any Error).self) { try Assistant.parse(Data(refusal.utf8), provider: .anthropic, allowed: allowed) }
        let none = #"{"stop_reason":"end_turn","content":[{"type":"text","text":"Swivel can't send email."}]}"#
        #expect(try Assistant.parse(Data(none.utf8), provider: .anthropic, allowed: allowed) == .init(actionID: nil, message: "Swivel can't send email."))

        let openAI = #"{"choices":[{"message":{"content":null,"tool_calls":[{"type":"function","function":{"name":"choose_action","arguments":"{\"action_id\":\"convert.PDF\",\"explanation\":\"合并成一个 PDF。\"}"}}]}}]}"#
        #expect(try Assistant.parse(Data(openAI.utf8), provider: .openAICompatible, allowed: allowed)
                == .init(actionID: "convert.PDF", message: "合并成一个 PDF。"))
    }

    @Test func keysBelongToOneHostAndSavedCodeNamesAreNeverOffered() {
        let deepseek = Assistant.Settings(provider: .openAICompatible, baseURL: "https://api.deepseek.com", model: "m")
        var local = deepseek; local.baseURL = "http://localhost:8080/v1"
        var other = deepseek; other.baseURL = "https://api.deepseek.com.evil.example"
        let accounts = [deepseek, local, other, .standard].compactMap(Assistant.account)
        #expect(accounts.count == 4 && Set(accounts).count == 4)
        #expect(Assistant.account(local) == "openAICompatible@localhost:8080")

        let commands = [QuickCommand(id: "codes.qr.1234", title: "passport scan", detail: "Codes", symbol: "qrcode") { nil },
                        QuickCommand(id: "tools.Compress", title: "Compress", detail: "Tools", symbol: "slider.horizontal.3") { nil },
                        QuickCommand(id: QuickActions.askID, title: "Ask", detail: "", symbol: "sparkles") { nil }]
        #expect(QuickActions.assistantChoices(commands).map(\.id) == ["tools.Compress"])
    }

    @Test func redirectsAreNeverFollowedWithTheKey() async throws {
        final class Redirecting: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var hosts: [String] = []
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Self.hosts.append(request.url?.host() ?? "")
                let target = URLRequest(url: URL(string: "https://attacker.example/steal")!)
                let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil,
                                               headerFields: ["Location": target.url!.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: target, redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Redirecting.self]
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        let request = try Assistant.makeRequest(.standard, key: "sk-secret", request: "x", choices: choices, files: "")
        Redirecting.hosts = []
        let (_, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 307)
        #expect(Redirecting.hosts == ["api.anthropic.com"])
    }

    @Test func suggestionsGoThroughTheConfiguredServiceAndReportHttpErrors() async throws {
        let defaults = UserDefaults.standard, keys = ["assistant.v1", "feature.quickActions"]
        let before = keys.map { defaults.object(forKey: $0) }
        let original = Assistant.session
        defer {
            for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
            Assistant.session = original
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        Assistant.session = URLSession(configuration: configuration)
        // A local server needs no key, so the keychain isn't touched by this test.
        Prefs.assistant = Assistant.Settings(provider: .openAICompatible, baseURL: "http://127.0.0.1:9/v1", model: "local-model")
        Prefs.setFeatureEnabled(.quickActions, true)
        #expect(Assistant.isReady)

        StubProtocol.sent = []
        StubProtocol.reply = (200, Data(#"{"choices":[{"message":{"tool_calls":[{"function":{"name":"choose_action","arguments":"{\"action_id\":\"tools.Compress\",\"explanation\":\"Smaller.\"}"}}]}}]}"#.utf8))
        let pick = try await Assistant.suggest("shrink", choices: choices, files: files)
        #expect(pick.actionID == "tools.Compress")
        #expect(StubProtocol.sent.count == 1)

        StubProtocol.reply = (401, Data(#"{"error":{"message":"bad key"}}"#.utf8))
        await #expect(throws: (any Error).self) { try await Assistant.suggest("shrink", choices: choices, files: files) }
    }
}
