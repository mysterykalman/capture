import Darwin
import Foundation

// CaptureNativeHost — the Chrome Native Messaging host binary.
//
// Chrome launches this process once per `chrome.runtime.connectNative`
// call from the extension's service worker and talks to it over this
// process's stdin/stdout using length-prefixed JSON frames (see
// `StdioFraming.swift`). This host does no message validation of its
// own beyond basic framing sanity — it forwards each frame verbatim over
// a Unix-domain socket to Capture.app (`SocketClient.swift`), which is
// where `CaptureBrowserBridge` actually validates and dispatches it (see
// docs/IPC_PROTOCOL.md). The only frames this process constructs itself
// are synthesized `INTERNAL_ERROR` / `PAYLOAD_TOO_LARGE` responses for
// when Capture.app can't be reached at all.
//
// Ignore SIGPIPE: if Chrome tears down its end of stdout (or
// Capture.app's end of the socket) out from under a write, we want that
// surfaced as an EPIPE error we can catch and log, not an immediate
// process kill.
signal(SIGPIPE, SIG_IGN)

let socketPath = NSHomeDirectory() + "/Library/Application Support/Capture/IPC/capture.sock"

// Named to avoid shadowing the C `stdin`/`stdout` globals (Swift permits
// it, but the shadowing reads as a landmine for a future maintainer).
let stdinHandle = FileHandle.standardInput
let stdoutHandle = FileHandle.standardOutput
let reader = FrameReader(handle: stdinHandle)

func logError(_ message: String) {
    FileHandle.standardError.write(Data(("CaptureNativeHost: " + message + "\n").utf8))
}

/// Writes a synthesized `{version, id, ok: false, error}` frame to
/// stdout so Chrome (and the extension's pending-request map) gets a
/// real rejection instead of hanging forever.
func sendErrorFrame(id: String, code: IPCErrorCode, message: String) {
    do {
        let response = IPCErrorResponse(id: id, code: code, message: message)
        try StdioFraming.writeFrame(response.encoded(), to: stdoutHandle)
    } catch {
        logError("failed to write synthesized error frame: \(error)")
    }
}

/// Attempts a single connect to the app's Unix socket. Returns `nil`
/// (rather than throwing) on any failure — callers decide what, if
/// anything, to do about it.
func attemptConnect(socketPath: String) -> SocketClient? {
    let client = SocketClient()
    do {
        try client.connect(path: socketPath)
        return client
    } catch {
        return nil
    }
}

/// Launches Capture.app in the background via `/usr/bin/open -g -b
/// com.capture.app` (per docs/IPC_PROTOCOL.md). Uses `Process` rather
/// than `NSWorkspace` so this package never has to `import AppKit` —
/// staying dependency-free and fast-launching is the whole point of this
/// binary being a separate SwiftPM package from `mac/` (see
/// `native-host/Package.swift`).
func launchCaptureApp() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-b", "com.capture.app"]
    do {
        try process.run()
        // Deliberately not waiting for exit: `open` hands off to Launch
        // Services and returns quickly regardless of whether Capture.app
        // itself has finished launching — the retry/backoff loop below is
        // what actually waits for the socket to become connectable.
    } catch {
        logError("failed to launch Capture.app via /usr/bin/open: \(error)")
    }
}

/// Connects to Capture.app's IPC socket, launching the app and retrying
/// with a short bounded backoff if it's not there yet
/// (docs/IPC_PROTOCOL.md: "the host may launch it ... and retry
/// connecting to the socket for a short bounded interval before
/// returning INTERNAL_ERROR"). Returns `nil` if the app still isn't
/// reachable once the retry budget is spent.
func connectToApp(socketPath: String) -> SocketClient? {
    if let client = attemptConnect(socketPath: socketPath) {
        return client
    }

    logError("Capture.app not reachable at \(socketPath); launching it and retrying.")
    launchCaptureApp()

    let retryInterval: TimeInterval = 0.25
    let maxAttempts = 8 // ~2s of backoff after the launch call
    for attempt in 1...maxAttempts {
        Thread.sleep(forTimeInterval: retryInterval)
        if let client = attemptConnect(socketPath: socketPath) {
            logError("connected to Capture.app after launch (attempt \(attempt)/\(maxAttempts)).")
            return client
        }
    }

    logError("gave up connecting to Capture.app after launch + \(maxAttempts) retries.")
    return nil
}

// Reused across messages within this process's lifetime (Chrome may send
// several messages over one native-messaging connection before the port
// is disconnected) — only pay the connect/launch/retry cost when there's
// no live connection to reuse.
var appClient: SocketClient?

messageLoop: while true {
    let requestData: Data
    do {
        guard let frame = try reader.readFrame() else {
            // Clean EOF: Chrome closed stdin — the extension disconnected
            // the native messaging port, or the browser is shutting down.
            break messageLoop
        }
        requestData = frame
    } catch FramingError.frameTooLarge(let declaredLength) {
        logError("rejecting oversized frame (\(declaredLength) bytes) from Chrome; exiting.")
        sendErrorFrame(
            id: fallbackRequestId(),
            code: .payloadTooLarge,
            message: "Frame exceeds the maximum allowed size."
        )
        break messageLoop
    } catch {
        logError("stdin framing error, exiting: \(error)")
        break messageLoop
    }

    let requestId = InboundRequestIdentity.extractId(from: requestData) ?? fallbackRequestId()

    if appClient == nil {
        appClient = connectToApp(socketPath: socketPath)
    }

    guard let client = appClient else {
        sendErrorFrame(
            id: requestId,
            code: .internalError,
            message: "Capture.app is not reachable over the IPC socket."
        )
        continue messageLoop
    }

    do {
        try client.sendFrame(requestData)
        let responseData = try client.receiveFrame()
        try StdioFraming.writeFrame(responseData, to: stdoutHandle)
    } catch {
        // Treat the connection as dead so the next message re-attempts
        // connect (+ launch/retry) from scratch, and tell Chrome this
        // particular request failed rather than leaving it hanging.
        client.close()
        appClient = nil
        logError("lost connection to Capture.app while forwarding a message: \(error)")
        sendErrorFrame(
            id: requestId,
            code: .internalError,
            message: "Lost connection to Capture.app while forwarding the message."
        )
    }
}

appClient?.close()
