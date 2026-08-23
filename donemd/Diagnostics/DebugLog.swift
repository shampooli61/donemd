import Foundation

/// File-based debug logger.
///
/// `NSLog` no longer surfaces in Console.app's unified log on macOS 26 /
/// Xcode 26 the way it used to, so we tail-append to a file instead. Only
/// active in DEBUG builds — release builds compile this to a no-op.
///
/// Usage: `debugLog("[area] something happened")`
/// View:  `cat /tmp/donemd-debug.log` (or `tail -f`)
#if DEBUG
private let debugLogURL = URL(fileURLWithPath: "/tmp/donemd-debug.log")
#endif

func debugLog(_ message: String) {
    #if DEBUG
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: debugLogURL.path) {
        if let handle = try? FileHandle(forWritingTo: debugLogURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    } else {
        try? data.write(to: debugLogURL)
    }
    #endif
}
