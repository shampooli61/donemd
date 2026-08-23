import Foundation

/// Routes typed envelopes between Swift and the embedded WKWebView.
///
/// Phase 1 uses one inbound type from JS (`editorReady`) and one outbound
/// type to JS (`loadDocument`); later slices add more without changing the
/// envelope schema.
///
/// This file holds the *pure* logic only — encode, decode, dispatch. The
/// WKWebView glue layer lives separately so this part is unit-testable
/// without spinning up a web view.
public final class WebViewBridge {
    public typealias Handler = (BridgeEnvelope) throws -> Void

    private var handlers: [String: Handler] = [:]
    private var fallback: Handler?

    public init() {}

    // MARK: Registration

    /// Register a handler for a given envelope `type`. Replaces any existing
    /// handler for that type.
    public func register(type: String, handler: @escaping Handler) {
        handlers[type] = handler
    }

    /// Set the fallback handler invoked when an inbound envelope's `type`
    /// has no specific registration.
    public func setFallback(_ handler: @escaping Handler) {
        fallback = handler
    }

    // MARK: Dispatch

    /// Validate and route an envelope to the matching handler.
    public func dispatch(_ envelope: BridgeEnvelope) throws {
        guard envelope.version == BridgeEnvelope.currentVersion else {
            throw BridgeError.unsupportedVersion(
                received: envelope.version,
                current: BridgeEnvelope.currentVersion
            )
        }
        if let handler = handlers[envelope.type] {
            try handler(envelope)
        } else if let fallback = fallback {
            try fallback(envelope)
        } else {
            throw BridgeError.unknownType(envelope.type)
        }
    }

    /// Decode raw JSON bytes (typically the payload of a `WKScriptMessage`)
    /// into an envelope and dispatch.
    public func dispatch(rawJSON data: Data) throws {
        let envelope: BridgeEnvelope
        do {
            envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: data)
        } catch {
            throw BridgeError.decodeFailure(String(describing: error))
        }
        try dispatch(envelope)
    }

    // MARK: Encoding (Swift → JS)

    /// Encode an envelope as a JSON string ready to splice into an
    /// `evaluateJavaScript("...")` call.
    public func encode(_ envelope: BridgeEnvelope) throws -> String {
        let data = try JSONEncoder().encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw BridgeError.decodeFailure("envelope encoding produced non-UTF8 bytes")
        }
        return json
    }
}
