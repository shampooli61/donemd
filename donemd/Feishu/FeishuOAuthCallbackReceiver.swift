import Foundation
import Network

/// Awaits the OAuth redirect that comes back to Done.md after the user
/// grants permission inside the Feishu authorize page. The interface is
/// abstracted so unit tests can stub it without binding to a real port.
public protocol FeishuOAuthCallbackReceiver {
    /// The redirect URI the receiver listens at — this is what gets
    /// embedded in the authorize URL. Must match the value registered
    /// in the Feishu open platform's "重定向 URL" list verbatim.
    var redirectURI: String { get }

    /// Block until the user's browser hits the redirect URI. Returns the
    /// full URL (so the caller can extract `code` and verify `state`),
    /// or throws on timeout / cancel / network error.
    ///
    /// `expectedState` is matched inside the receiver so the success page
    /// shown to the user can call out CSRF mismatches before the URL is
    /// surfaced to the caller.
    func awaitCallback(expectedState: String, timeout: TimeInterval) async throws -> URL
}

/// Loopback HTTP listener — Feishu's open platform rejects custom URL
/// schemes (only http/https since 2023), so v2-2B-2 follows the gh /
/// gcloud / rclone desktop-OAuth pattern: register
/// `http://localhost:<port>/oauth/callback` as the redirect URI; spin up
/// an NWListener on that port for the duration of the login flow; tear
/// it down after the first request.
///
/// The HTTP parser here is intentionally minimal — it speaks just enough
/// HTTP/1.1 to grab the request line, return a 200 response with a
/// "you can close this tab" page, and shut down. No keep-alive, no chunked,
/// no body parsing (the redirect is GET-only). Anything more would be a
/// liability for a 5-second-uptime listener.
public final class FeishuOAuthLoopbackReceiver: FeishuOAuthCallbackReceiver {

    public enum ReceiverError: Error, Equatable {
        case portInUse(UInt16)
        case listenerFailed(String)
        case malformedRequest
        case stateMismatch
        case timedOut
        case cancelled
    }

    public let port: UInt16
    public let path: String
    public var redirectURI: String { "http://localhost:\(port)\(path)" }

    private let queue: DispatchQueue

    public init(port: UInt16 = 18127, path: String = "/oauth/callback") {
        self.port = port
        self.path = path
        self.queue = DispatchQueue(label: "feishu-oauth-loopback.\(port)")
    }

    public func awaitCallback(
        expectedState: String,
        timeout: TimeInterval = 300
    ) async throws -> URL {
        let listener: NWListener
        do {
            let params = NWParameters.tcp
            // Bind only to loopback; rejecting external interfaces narrows
            // the attack surface to "code running as the same user", which
            // is the same trust boundary the keychain already enforces.
            params.requiredInterfaceType = .loopback
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            throw ReceiverError.portInUse(port)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let handoff = ContinuationHandoff(continuation: continuation)
                let timeoutWorkItem = DispatchWorkItem {
                    handoff.fail(ReceiverError.timedOut)
                    listener.cancel()
                }
                queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

                listener.stateUpdateHandler = { state in
                    if case .failed(let err) = state {
                        handoff.fail(ReceiverError.listenerFailed(err.localizedDescription))
                        listener.cancel()
                        timeoutWorkItem.cancel()
                    }
                }

                listener.newConnectionHandler = { [path = self.path, expectedState] connection in
                    connection.start(queue: self.queue)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                        defer {
                            connection.cancel()
                            listener.cancel()
                            timeoutWorkItem.cancel()
                        }
                        guard let data = data,
                              let request = String(data: data, encoding: .utf8),
                              let urlString = parseRequestLineURL(from: request, host: "localhost", port: self.port),
                              let components = URLComponents(string: urlString),
                              components.path == path
                        else {
                            sendResponse(over: connection, status: 400, body: "<h1>Bad Request</h1>")
                            handoff.fail(ReceiverError.malformedRequest)
                            return
                        }
                        let queryItems = components.queryItems ?? []
                        let returnedState = queryItems.first(where: { $0.name == "state" })?.value
                        guard returnedState == expectedState else {
                            sendResponse(over: connection, status: 400,
                                body: "<h1>State mismatch</h1><p>Possible CSRF — please retry login from Done.md.</p>")
                            handoff.fail(ReceiverError.stateMismatch)
                            return
                        }
                        sendResponse(over: connection, status: 200,
                            body: "<h1>登录成功</h1><p>已授权 Done.md，可关闭此窗口返回应用。</p>")
                        handoff.succeed(URL(string: urlString)!)
                    }
                }

                listener.start(queue: queue)
            }
        } onCancel: {
            // External Task cancellation — tear down the listener so the
            // port is released even if the await never resumes.
            listener.cancel()
        }
    }
}

// MARK: - private helpers

/// One-shot handoff so the continuation is guaranteed to resume exactly
/// once even when the timeout fires the same instant a connection lands.
private final class ContinuationHandoff: @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func succeed(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(returning: url)
        continuation = nil
    }

    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Extract the request-line URL from a raw HTTP/1.1 request. The Feishu
/// redirect always arrives as a single GET — anything else (HEAD probes,
/// CORS preflights from random local services) returns nil so we can 400.
private func parseRequestLineURL(from request: String, host: String, port: UInt16) -> String? {
    guard let firstLine = request.split(separator: "\r\n").first else { return nil }
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET" else { return nil }
    let pathAndQuery = String(parts[1])
    return "http://\(host):\(port)\(pathAndQuery)"
}

private func sendResponse(over connection: NWConnection, status: Int, body: String) {
    let statusText = status == 200 ? "OK" : "Bad Request"
    let bodyData = body.data(using: .utf8) ?? Data()
    let header = """
    HTTP/1.1 \(status) \(statusText)\r
    Content-Type: text/html; charset=utf-8\r
    Content-Length: \(bodyData.count)\r
    Connection: close\r
    \r

    """
    var payload = Data(header.utf8)
    payload.append(bodyData)
    connection.send(content: payload, completion: .contentProcessed { _ in })
}
