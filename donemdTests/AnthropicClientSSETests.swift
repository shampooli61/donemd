import XCTest
@testable import donemd

/// Phase 3 Slice 7 (#68) — M1 SSE parsing + request shape for the Anthropic
/// Messages protocol family (Claude).
///
/// The line parser is pure, so we test the wire-format handling directly
/// without a network round-trip. End-to-end streaming (real Claude SSE)
/// is covered by the manual device test in the issue's acceptance criteria.
final class AnthropicClientSSETests: XCTestCase {

    private func parse(_ line: String) -> AnthropicClient.SSELineResult {
        AnthropicClient.parseSSELine(line)
    }

    func testContentBlockDeltaYieldsToken() {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}"#
        XCTAssertEqual(parse(line), .token("你好"))
    }

    func testMessageStopIsDone() {
        XCTAssertEqual(parse(#"data: {"type":"message_stop"}"#), .done)
    }

    func testBlankLineIgnored() {
        XCTAssertEqual(parse(""), .ignore)
        XCTAssertEqual(parse("   "), .ignore)
    }

    func testEventLineIgnored() {
        // SSE carries `event:` lines alongside `data:` — keyed off JSON type,
        // so the event line itself is ignored.
        XCTAssertEqual(parse("event: content_block_delta"), .ignore)
    }

    func testMessageStartIgnored() {
        let line = #"data: {"type":"message_start","message":{"id":"msg_1"}}"#
        XCTAssertEqual(parse(line), .ignore)
    }

    func testContentBlockStartIgnored() {
        let line = #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
        XCTAssertEqual(parse(line), .ignore)
    }

    func testPingIgnored() {
        XCTAssertEqual(parse(#"data: {"type":"ping"}"#), .ignore)
    }

    func testEmptyTextDeltaIgnored() {
        let line = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":""}}"#
        XCTAssertEqual(parse(line), .ignore)
    }

    func testNonTextDeltaIgnored() {
        // input_json_delta (tool args) carries no text — must be ignored.
        let line = #"data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}"#
        XCTAssertEqual(parse(line), .ignore)
    }

    func testGarbageLineIgnored() {
        XCTAssertEqual(parse("data: not json at all"), .ignore)
        XCTAssertEqual(parse(": this is an SSE comment"), .ignore)
    }

    func testMultiCharContentPreserved() {
        let line = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"一段较长的中文内容。"}}"#
        XCTAssertEqual(parse(line), .token("一段较长的中文内容。"))
    }

    // MARK: - request building

    func testStreamRequestShape() throws {
        let client = AnthropicClient(baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "sk-ant-test")
        let req = client.makeStreamRequest(
            messages: [
                AIMessage(role: .system, content: "sys"),
                AIMessage(role: .user, content: "hi"),
            ],
            model: "claude-haiku-4-5"
        )
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), AnthropicClient.anthropicVersion)
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, AnthropicClient.maxTokens)
        // system is lifted to a top-level field, not a messages[] entry.
        XCTAssertEqual(json["system"] as? String, "sys")
        let msgs = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0]["role"], "user")
        XCTAssertEqual(msgs[0]["content"], "hi")
    }

    func testRequestSendsAPIKeyHeader() throws {
        let client = AnthropicClient(baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "sk-claude")
        let req = client.makeStreamRequest(
            messages: [AIMessage(role: .user, content: "hi")],
            model: "claude-haiku-4-5"
        )
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-claude")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), AnthropicClient.anthropicVersion)
    }

    func testRequestWithNoSystemMessageOmitsSystemField() throws {
        let client = AnthropicClient(baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "k")
        let req = client.makeStreamRequest(
            messages: [AIMessage(role: .user, content: "hi")],
            model: "claude-haiku-4-5"
        )
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["system"])
    }
}
