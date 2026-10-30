import XCTest
@testable import donemdIOS

@MainActor
final class MobileThemeStoreTests: XCTestCase {
    private func fixture(saved: String? = nil, legacy: String = "") -> (MobileThemeStore, MobileEditorController, UserDefaults) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        if let saved { defaults.set(saved, forKey: MobileThemeStore.preferenceKey) }
        let controller = MobileEditorController()
        controller.installTransport({ command in
            var state = controller.state
            state.theme = command.args["theme"] ?? state.theme
            controller.receive(result: .init(requestId: command.requestId, success: true, state: state))
        }, currentSource: { nil })
        controller.prepare(identity: "note", revision: 3)
        var state = controller.state
        state.ready = true; state.theme = legacy; state.fontSize = 22
        controller.receive(state: state)
        return (MobileThemeStore(defaults: defaults), controller, defaults)
    }

    func testNoSourceFailsClosedWithoutBodyOrPreferenceChange() async {
        let (store, controller, defaults) = fixture()
        let result = await store.apply(.night, using: controller)
        XCTAssertFalse(result)
        XCTAssertEqual(store.theme, .system)
        XCTAssertEqual(controller.state.theme, "")
        XCTAssertNil(defaults.string(forKey: MobileThemeStore.preferenceKey))
    }

    func testSourceFailureRollsBothDisplaysBackWithoutPersisting() async {
        let (store, controller, defaults) = fixture(saved: "paper", legacy: "paper")
        var source: [MobileWritingTheme] = []
        store.attachSource(owner: UUID()) { theme in source.append(theme); return theme == .paper }
        let result = await store.apply(.night, using: controller)
        XCTAssertFalse(result)
        XCTAssertEqual(source, [.night, .paper])
        XCTAssertEqual(controller.state.theme, "paper")
        XCTAssertEqual(store.theme, .paper)
        XCTAssertEqual(defaults.string(forKey: MobileThemeStore.preferenceKey), "paper")
        XCTAssertNotNil(store.error)
    }

    func testAllThemesCommitOnlyAfterBothACKsAndPreserveFont() async {
        let (store, controller, defaults) = fixture()
        store.attachSource(owner: UUID()) { next in
            XCTAssertNotEqual(defaults.string(forKey: MobileThemeStore.preferenceKey), next.rawValue)
            return true
        }
        for next in [MobileWritingTheme.paper, .night, .system] {
            let result = await store.apply(next, using: controller)
            XCTAssertTrue(result)
            XCTAssertEqual(store.theme, next)
            XCTAssertEqual(defaults.string(forKey: MobileThemeStore.preferenceKey), next.rawValue)
            XCTAssertEqual(controller.state.theme, next.webValue)
            XCTAssertEqual(controller.state.fontSize, 22)
        }
    }

    func testReconcileMigratesLegacyOnceThenNativePreferenceWins() async {
        let (store, controller, defaults) = fixture(legacy: "night")
        store.attachSource(owner: UUID()) { _ in true }
        await store.reconcile(using: controller)
        XCTAssertEqual(store.theme, .night)
        XCTAssertEqual(defaults.string(forKey: MobileThemeStore.preferenceKey), "night")
        var legacy = controller.state; legacy.theme = "paper"; controller.receive(state: legacy)
        await store.reconcile(using: controller)
        XCTAssertEqual(controller.state.theme, "night")
    }

    func testInitialSourceNotReadyKeepsLatchedLegacyCandidateAcrossRollbackAndRetry() async {
        let (store, controller, defaults) = fixture(legacy: "night")
        var sourceReady = false
        var sourceThemes: [MobileWritingTheme] = []
        store.attachSource(owner: UUID()) { next in
            sourceThemes.append(next)
            return sourceReady
        }
        await store.reconcile(using: controller)
        XCTAssertEqual(sourceThemes, [.night, .system])
        XCTAssertEqual(controller.state.theme, "", "Initial failure rolls the body back to native system")
        XCTAssertEqual(store.theme, .system)
        XCTAssertNil(defaults.string(forKey: MobileThemeStore.preferenceKey))

        // The source page becomes ready after body state already reports rollback.
        sourceReady = true
        await store.reconcile(using: controller)
        XCTAssertEqual(sourceThemes, [.night, .system, .night])
        XCTAssertEqual(controller.state.theme, "night")
        XCTAssertEqual(store.theme, .night)
        XCTAssertEqual(defaults.string(forKey: MobileThemeStore.preferenceKey), "night")
        XCTAssertNil(store.error)

        // Once committed, later stale web preferences cannot replace native authority.
        var stale = controller.state; stale.theme = "paper"; controller.receive(state: stale)
        await store.reconcile(using: controller)
        XCTAssertEqual(controller.state.theme, "night")
    }

    func testSourceReadyDuringSuspendedRollbackAutomaticallyReconcilesOnce() async {
        let (store, controller, defaults) = fixture(legacy: "night")
        let rollbackSent = expectation(description: "body rollback suspended")
        let retriedSource = expectation(description: "latched night retried after readiness signal")
        var rollback: MobileEditorCommand?
        controller.installTransport({ command in
            if command.args["theme"] == "" && rollback == nil {
                rollback = command
                rollbackSent.fulfill()
                return
            }
            var state = controller.state
            state.theme = command.args["theme"] ?? state.theme
            controller.receive(result: .init(requestId: command.requestId, success: true, state: state))
        }, currentSource: { nil })
        var initial = controller.state; initial.ready = true; initial.theme = "night"; controller.receive(state: initial)
        var sourceReady = false
        var attempted: [MobileWritingTheme] = []
        store.attachSource(owner: UUID()) { next in
            attempted.append(next)
            if sourceReady && next == .night { retriedSource.fulfill() }
            return sourceReady
        }
        let first = Task { await store.reconcile(using: controller) }
        await fulfillment(of: [rollbackSent], timeout: 1)
        XCTAssertTrue(store.applying)
        sourceReady = true
        // This is the sole readiness signal. No manual retry after rollback.
        await store.reconcile(using: controller)
        var rolledBack = controller.state; rolledBack.theme = ""
        controller.receive(result: .init(requestId: rollback!.requestId, success: true, state: rolledBack))
        await first.value
        await fulfillment(of: [retriedSource], timeout: 1)
        XCTAssertEqual(attempted, [.night, .system, .night])
        XCTAssertEqual(store.theme, .night)
        XCTAssertEqual(controller.state.theme, "night")
        XCTAssertEqual(defaults.string(forKey: MobileThemeStore.preferenceKey), "night")
        XCTAssertFalse(store.applying)
    }

    func testReconcileCannotOverrideInflightUserChoiceOrCommitBeforeSourceACK() async {
        let (store, controller, defaults) = fixture(legacy: "paper")
        let reachedSource = expectation(description: "waiting for source ACK")
        var continuation: CheckedContinuation<Bool, Never>?
        var sourceCalls = 0
        store.attachSource(owner: UUID()) { _ in
            sourceCalls += 1
            if sourceCalls > 1 { return true }
            return await withCheckedContinuation { pending in continuation = pending; reachedSource.fulfill() }
        }
        let apply = Task { await store.apply(.night, using: controller) }
        await fulfillment(of: [reachedSource], timeout: 1)
        XCTAssertTrue(store.applying)
        XCTAssertEqual(store.theme, .system)
        XCTAssertNil(defaults.string(forKey: MobileThemeStore.preferenceKey))
        await store.reconcile(using: controller)
        continuation?.resume(returning: true)
        let accepted = await apply.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(store.theme, .night)
    }
    func testBodyFailureDoesNotCommitAndRollsSourceToPreviousTheme() async {
        let (store, controller, defaults) = fixture(saved: "paper", legacy: "paper")
        var source: [MobileWritingTheme] = []
        controller.installTransport({ command in
            controller.receive(result: .init(requestId: command.requestId, success: command.args["theme"] == "paper"))
        }, currentSource: { nil })
        var ready = controller.state; ready.ready = true; controller.receive(state: ready)
        store.attachSource(owner: UUID()) { next in source.append(next); return true }
        let result = await store.apply(.night, using: controller)
        XCTAssertFalse(result)
        XCTAssertEqual(source, [.paper])
        XCTAssertEqual(store.theme, .paper)
        XCTAssertEqual(defaults.string(forKey: MobileThemeStore.preferenceKey), "paper")
    }

}
