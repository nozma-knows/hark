import Foundation
import OSLog

/// `CrashReportSink` implementation that POSTs the formatted payload to
/// a configurable HTTPS endpoint as JSON. The default Hark binary
/// ships with this sink wired but disabled — users opt in by setting
/// the endpoint URL in Settings → General → "Crash uploads."
///
/// Why not a Sentry SDK direct integration: we need to ship without
/// any embedded telemetry credentials, the JSON shape is small enough
/// that a generic HTTP POST works against Sentry's `/api/<n>/store/`
/// endpoint, a Slack webhook, or a custom receiver — and adopting a
/// vendor SDK would lock the choice in code. This way the user picks.
///
/// Reliability:
///   - Best-effort. We never block the next-launch finalizer waiting on
///     a network response, and we never raise an error from a sink
///     callback — that path is already inside crash-recovery code.
///   - URLSession's ephemeral configuration so cookies/credentials
///     can't leak from the user's other apps.
///   - 5-second timeout so a hung endpoint doesn't stall app launch.
///
/// Privacy: the payload contains app version, signal name, formatted
/// stack frames, and a timestamp. NO user content (transcripts, audio,
/// keychain contents). The endpoint URL is opt-in and per-machine.
final class HttpCrashSink: CrashReportSink {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "HttpCrashSink")

    let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .ephemeralSink) {
        self.endpoint = endpoint
        self.session = session
    }

    func capture(_ payload: CrashReporter.CrashPayload) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let body = Self.makeJsonBody(payload: payload, appVersion: version, build: build)

        guard let data = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            Self.logger.error("Failed to encode crash payload as JSON")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Hark/\(version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = data

        // Fire-and-forget. We log success/failure but don't block.
        let task = session.dataTask(with: request) { _, response, error in
            if let error {
                Self.logger.error("Crash upload failed: \(String(describing: error), privacy: .public)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200...299).contains(status) {
                Self.logger.error("Crash upload returned HTTP \(status)")
                return
            }
            Self.logger.info("Crash upload accepted (\(status))")
        }
        task.resume()
    }

    /// Pure: build the JSON-ready dictionary. Exposed `internal` so
    /// tests can pin the wire shape without spinning up a real
    /// URLSession.
    static func makeJsonBody(
        payload: CrashReporter.CrashPayload,
        appVersion: String,
        build: String
    )
        -> [String: Any]
    {
        var body: [String: Any] = [
            "kind": payload.kind,
            "detail": payload.detail,
            "timestamp": ISO8601DateFormatter().string(from: payload.timestamp),
            "appVersion": appVersion,
            "build": build,
            "pid": Int(getpid()),
            "stack": payload.stack
        ]
        if let signal = payload.signal {
            body["signal"] = Int(signal)
            body["signalName"] = CrashReporter.signalName(signal)
        }
        return body
    }
}

extension URLSession {
    /// Shared ephemeral session for crash uploads. No persistent cookies
    /// or credential cache (the user's Mac may have cookies for an
    /// unrelated host at the same domain), short timeout so a hung
    /// endpoint can't stall the finalizer.
    static let ephemeralSink: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()
}

/// Tiny preferences wrapper. Single source of truth for the
/// user-configured endpoint URL; UserDefaults-backed so it survives
/// relaunches. Empty string means "disabled" — used by AppDelegate's
/// install path to decide whether to attach a sink at all.
enum CrashUploadPreferences {
    private static let endpointKey = "co.milbo.hark.crashUploadEndpoint"

    /// Returns the user-supplied URL string, or nil if unset / empty.
    /// Doesn't validate — `URL(string:)` is the parse, this is just storage.
    static var endpointString: String? {
        let raw = UserDefaults.standard.string(forKey: endpointKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func setEndpoint(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: endpointKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: endpointKey)
        }
    }

    /// Build a sink instance from the persisted endpoint, or nil if the
    /// user hasn't opted in. Defensive: invalid URLs return nil instead
    /// of crashing the install path.
    static func buildSinkIfConfigured() -> HttpCrashSink? {
        guard let raw = endpointString, let url = URL(string: raw) else {
            return nil
        }
        // Require https — refusing http stops the sink from accidentally
        // sending crash data over the network in plaintext if the user
        // pastes an http:// URL.
        guard url.scheme == "https" else { return nil }
        return HttpCrashSink(endpoint: url)
    }
}
