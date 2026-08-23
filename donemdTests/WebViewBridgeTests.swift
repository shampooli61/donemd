import XCTest
@testable import donemd

final class WebViewBridgeTests: XCTestCase {

    // MARK: Envelope round-trip

    func testEnvelopeRoundTripPreservesAllPayloadKinds() throws {
        let original = BridgeEnvelope(
            type: "loadDocument",
            payload: .object([
                "title": .string("Hello"),
                "level": .integer(1),
                "ratio": .double(1.5),
                "bold": .bool(true),
                "missing": .null,
                "tags": .array([.string("a"), .string("b")]),
                "nested": .object(["k": .string("v")])
            ])
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(BridgeEnvelope.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testEnvelopeJSONShape() throws {
        let envelope = BridgeEnvelope(
            type: "editorReady",
            payload: .object([:])
        )
        let bridge = WebViewBridge()
        let json = try bridge.encode(envelope)

        // Just spot-check the JSON contains the three top-level keys.
        XCTAssertTrue(json.contains("\"version\":1"), "json: \(json)")
        XCTAssertTrue(json.contains("\"type\":\"editorReady\""), "json: \(json)")
        XCTAssertTrue(json.contains("\"payload\":"), "json: \(json)")
    }

    // MARK: Handler dispatch

    func testRegisteredHandlerReceivesMatchingType() throws {
        let bridge = WebViewBridge()
        var receivedType: String?
        bridge.register(type: "editorReady") { envelope in
            receivedType = envelope.type
        }

        let envelope = BridgeEnvelope(type: "editorReady", payload: .null)
        try bridge.dispatch(envelope)

        XCTAssertEqual(receivedType, "editorReady")
    }

    func testFallbackHandlerReceivesUnknownType() throws {
        let bridge = WebViewBridge()
        var fallbackInvokedFor: String?
        bridge.setFallback { envelope in
            fallbackInvokedFor = envelope.type
        }

        try bridge.dispatch(BridgeEnvelope(type: "weirdNewType", payload: .null))

        XCTAssertEqual(fallbackInvokedFor, "weirdNewType")
    }

    func testUnknownTypeWithoutFallbackThrows() {
        let bridge = WebViewBridge()
        XCTAssertThrowsError(
            try bridge.dispatch(BridgeEnvelope(type: "missing", payload: .null))
        ) { error in
            XCTAssertEqual(error as? BridgeError, .unknownType("missing"))
        }
    }

    func testRegisteredHandlerWinsOverFallback() throws {
        let bridge = WebViewBridge()
        var specificCalled = false
        var fallbackCalled = false
        bridge.register(type: "ping") { _ in specificCalled = true }
        bridge.setFallback { _ in fallbackCalled = true }

        try bridge.dispatch(BridgeEnvelope(type: "ping", payload: .null))

        XCTAssertTrue(specificCalled)
        XCTAssertFalse(fallbackCalled)
    }

    // MARK: Version validation

    func testVersionMismatchThrowsTypedError() {
        let bridge = WebViewBridge()
        let futureEnvelope = BridgeEnvelope(type: "x", payload: .null, version: 999)

        XCTAssertThrowsError(try bridge.dispatch(futureEnvelope)) { error in
            XCTAssertEqual(
                error as? BridgeError,
                .unsupportedVersion(received: 999, current: BridgeEnvelope.currentVersion)
            )
        }
    }

    // MARK: Raw JSON dispatch

    func testRawJSONDispatchRoutesCorrectly() throws {
        let bridge = WebViewBridge()
        var payloadCaptured: JSONValue?
        bridge.register(type: "editorReady") { envelope in
            payloadCaptured = envelope.payload
        }

        let json = #"{"version":1,"type":"editorReady","payload":{"hello":"world"}}"#
        try bridge.dispatch(rawJSON: Data(json.utf8))

        XCTAssertEqual(payloadCaptured, .object(["hello": .string("world")]))
    }

    func testRawJSONMalformedThrowsDecodeFailure() {
        let bridge = WebViewBridge()
        XCTAssertThrowsError(try bridge.dispatch(rawJSON: Data("not json".utf8))) { error in
            guard case .decodeFailure = error as? BridgeError else {
                XCTFail("expected .decodeFailure, got \(error)")
                return
            }
        }
    }
}
