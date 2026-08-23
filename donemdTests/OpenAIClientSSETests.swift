import XCTest
@testable import donemd

/// Phase 3 Slice 2 (#63) — M1 SSE parsing for the OpenAI-compatible stream.
///
/// The line parser is pure, so we test the wire-format handling directly
/// without a network round-trip. End-to-end streaming (real DeepSeek SSE) is
/// covered by the manual device test in the issue's acceptance criteria.
final class OpenAIClientSSETests: XCTestCase {

    private func parse(_ line: String) -> OpenAIClient.SSELineResult {
        OpenAIClient.parseSSELine(line)
    }

    func testContentDeltaYieldsToken() {
        let line = #"data: {"choices":[{"delta":{"content":"你好"}}]}"#
        XCTAssertEqual(parse(line), .token("你好"))
    }

    func testDoneSentinel() {
        XCTAssertEqual(parse("data: [DONE]"), .done)
    }

    func testBlankLineIgnored() {
        XCTAssertEqual(parse(""), .ignore)
        XCTAssertEqual(parse("   "), .ignore)
    }

    func testRoleOnlyDeltaIgnored() {
        // First chunk often carries {"delta":{"role":"assistant"}} with no
        // content — must be ignored, not yielded as empty text.
        let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        XCTAssertEqual(parse(line), .ignore)
    }

    func testEmptyContentIgnored() {
        let line = #"data: {"choices":[{"delta":{"content":""}}]}"#
        XCTAssertEqual(parse(line), .ignore)
    }

    func testFinishReasonChunkIgnored() {
        // Final chunk: delta empty + finish_reason set. No content → ignore.
        let line = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        XCTAssertEqual(parse(line), .ignore)
    }

    func testLineWithoutDataPrefixStillParsed() {
        // Some gateways drop the "data:" prefix; tolerate raw JSON lines.
        let line = #"{"choices":[{"delta":{"content":"x"}}]}"#
        XCTAssertEqual(parse(line), .token("x"))
    }

    func testWhitespaceAfterDataPrefixTrimmed() {
        let line = #"data:{"choices":[{"delta":{"content":"a"}}]}"#
        XCTAssertEqual(parse(line), .token("a"))
    }

    func testGarbageLineIgnored() {
        XCTAssertEqual(parse("data: not json at all"), .ignore)
        XCTAssertEqual(parse(": this is an SSE comment"), .ignore)
    }

    func testMultiCharContentPreserved() {
        let line = #"data: {"choices":[{"delta":{"content":"一段较长的中文内容。"}}]}"#
        XCTAssertEqual(parse(line), .token("一段较长的中文内容。"))
    }

    // MARK: - request building

    func testStreamRequestShape() throws {
        let client = OpenAIClient(baseURL: URL(string: "https://api.deepseek.com")!, apiKey: "sk-test")
        let req = client.makeStreamRequest(
            messages: [AIMessage(role: .system, content: "sys"), AIMessage(role: .user, content: "hi")],
            model: "deepseek-chat"
        )
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-chat")
        XCTAssertEqual(json["stream"] as? Bool, true)
        let msgs = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0]["role"], "system")
        XCTAssertEqual(msgs[1]["content"], "hi")
    }
}
