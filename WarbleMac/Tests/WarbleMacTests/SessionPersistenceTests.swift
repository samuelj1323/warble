import XCTest
@testable import WarbleMac

@MainActor
final class SessionPersistenceTests: XCTestCase {
    private func tempStore() -> (SessionStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("warble-tests-\(UUID().uuidString)")
            .appendingPathComponent("sessions.json")
        return (SessionStore(fileURL: url), url)
    }

    func testSessionConfigCodableRoundTrip() throws {
        let config = SessionConfig(
            repoRoot: "/tmp/scratch",
            agentModeEnabled: true,
            pasteTarget: .app(bundleID: "com.apple.Notes", name: "Notes"),
            claudeSessionID: "abc-123"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testPasteTargetFocusedAppRoundTrip() throws {
        let data = try JSONEncoder().encode(PasteTarget.focusedApp)
        XCTAssertEqual(try JSONDecoder().decode(PasteTarget.self, from: data), .focusedApp)
    }

    func testSessionStoreSaveThenLoad() {
        let (store, _) = tempStore()
        let state = PersistedState(
            sessions: [
                PersistedSession(
                    id: UUID(),
                    title: "Fix bug",
                    messages: [ChatMessage(id: UUID(), role: .user, text: "hi")],
                    config: SessionConfig(repoRoot: "/tmp/a", agentModeEnabled: true, pasteTarget: .focusedApp, claudeSessionID: "sid")
                )
            ],
            currentSessionID: nil
        )
        store.save(state)

        let loaded = store.load(PersistedState.self)
        XCTAssertEqual(loaded?.sessions.count, 1)
        XCTAssertEqual(loaded?.sessions.first?.title, "Fix bug")
        XCTAssertEqual(loaded?.sessions.first?.config.repoRoot, "/tmp/a")
        XCTAssertEqual(loaded?.sessions.first?.config.claudeSessionID, "sid")
        XCTAssertEqual(loaded?.sessions.first?.messages.first?.text, "hi")
    }

    func testSessionStoreLoadMissingFileReturnsNil() {
        let (store, _) = tempStore()
        XCTAssertNil(store.load(PersistedState.self))
    }

    func testSessionHistoryPersistsAndReloads() {
        let (store, _) = tempStore()

        let history = SessionHistory(store: store)
        let session = history.startNewSession()
        session.config.repoRoot = "/tmp/scratch"
        session.config.agentModeEnabled = true
        session.append(role: .user, text: "add a spinner")

        // A fresh history over the same store should see the persisted session.
        let reloaded = SessionHistory(store: store)
        XCTAssertEqual(reloaded.sessions.count, 1)
        let restored = reloaded.sessions.first
        XCTAssertEqual(restored?.id, session.id)
        XCTAssertEqual(restored?.config.repoRoot, "/tmp/scratch")
        XCTAssertTrue(restored?.config.agentModeEnabled ?? false)
        XCTAssertEqual(restored?.title, "add a spinner")
        XCTAssertEqual(reloaded.currentSessionID, session.id)
    }

    func testCodeSessionNilWithoutRepo() {
        let session = ChatSession()
        XCTAssertNil(session.codeSession, "no repo means no code-change session")
    }

    func testCodeSessionScopedToRepo() {
        let session = ChatSession(config: SessionConfig(repoRoot: "/tmp/scratch"))
        let code = session.codeSession
        XCTAssertNotNil(code)
        // Same session instance is returned while the repo is unchanged.
        XCTAssertIdentical(session.codeSession, code)
    }
}
