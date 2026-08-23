import XCTest
@testable import donemd

/// Phase 3 Slice 7 (#68) — M1 SSE parsing + request shape for the Google
/// Gemini generative API.
///
/// The line parser is pure, so we test the wire-format handling directly
/// without a network round-trip. End-to-end streaming (real Gemini SSE) is
/// covered by the manual device test in the issue's acceptance criteria.
final class GoogleClientSSETests: XCTestCase {

    private func parse(_ line: String) -> GoogleClient.SSELineResult {
        GoogleClient.parseSSELine(line)
    }

    func testCandidatePartYieldsToken() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"你好"}],"role":"model"}}]}"#
        XCTAssertEqual(parse(line), .token("你好"))
    }

    func testMultiplePartsJoined() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"foo"},{"text":"bar"}]}}]}"#
        XCTAssertEqual(parse(line), .token("foobar"))
    }

    func testBlankLineIgnored() {
        XCTAssertEqual(parse(""), .ignore)
        XCTAssertEqual(parse("   "), .ignore)
    }

    func testEventLineIgnored() {
        XCTAssertEqual(parse("event: message"), .ignore)
    }

    func testEmptyPartsIgnored() {
        let line = #"data: {"candidates":[{"content":{"parts":[]}}]}"#
        XCTAssertEqual(parse(line), .ignore)
    }

    func testNoCandidatesIgnored() {
        // usageMetadata-only chunks carry no candidates.
        let line = #"data: {"usageMetadata":{"promptTokenCount":3}}"#
        XCTAssertEqual(parse(line), .ignore)
    }

    func testGarbageLineIgnored() {
        XCTAssertEqual(parse("data: not json at all"), .ignore)
        XCTAssertEqual(parse(": comment"), .ignore)
    }

    func testMultiCharContentPreserved() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"一段较长的中文内容。"}]}}]}"#
        XCTAssertEqual(parse(line), .token("一段较长的中文内容。"))
    }

    // MARK: - role mapping

    func testAssistantRoleMapsToModel() {
        XCTAssertEqual(GoogleClient.googleRole(for: .assistant), "model")
        XCTAssertEqual(GoogleClient.googleRole(for: .user), "user")
    }

    func testStripModelsPrefix() {
        XCTAssertEqual(GoogleClient.stripModelsPrefix("models/gemini-2.5-flash"), "gemini-2.5-flash")
        XCTAssertEqual(GoogleClient.stripModelsPrefix("gemini-2.5-flash"), "gemini-2.5-flash")
    }

    // MARK: - request building

    func testStreamRequestShape() throws {
        let client = GoogleClient(baseURL: URL(string: "https://generativelanguage.googleapis.com")!, apiKey: "g-test")
        let req = client.makeStreamRequest(
            messages: [
                AIMessage(role: .system, content: "sys"),
                AIMessage(role: .user, content: "hi"),
            ],
            model: "gemini-2.5-flash"
        )
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(
            req.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
        )
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-goog-api-key"), "g-test")
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // system lifted to systemInstruction.
        let systemInstruction = try XCTUnwrap(json["systemInstruction"] as? [String: Any])
        let sysParts = try XCTUnwrap(systemInstruction["parts"] as? [[String: String]])
        XCTAssertEqual(sysParts.first?["text"], "sys")

        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: String]])
        XCTAssertEqual(parts.first?["text"], "hi")
    }

    func testRequestWithNoSystemMessageOmitsSystemInstruction() throws {
        let client = GoogleClient(baseURL: URL(string: "https://generativelanguage.googleapis.com")!, apiKey: "k")
        let req = client.makeStreamRequest(
            messages: [AIMessage(role: .user, content: "hi")],
            model: "gemini-2.5-flash"
        )
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["systemInstruction"])
    }
}
