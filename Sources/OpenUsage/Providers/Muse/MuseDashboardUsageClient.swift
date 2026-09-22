import Foundation
@preconcurrency import WebKit

enum MuseDashboardUsageError: Error, LocalizedError, Equatable {
    case invalidCookie
    case invalidPage
    case timeout
    case cooldown

    var errorDescription: String? {
        switch self {
        case .invalidCookie:
            return "The saved Meta dashboard session is invalid."
        case .invalidPage:
            return "Meta's usage dashboard did not contain Muse quota data."
        case .timeout:
            return "Meta's usage dashboard did not finish loading."
        case .cooldown:
            return "Meta's usage dashboard is waiting for the next safe refresh."
        }
    }
}

/// Loads Meta's authenticated usage page in an off-screen, non-persistent WebKit view and returns
/// only its rendered text. The mapper owns semantic parsing; this client deliberately knows nothing
/// about Meta's private GraphQL document ids or dynamic request fields.
@MainActor
final class MuseDashboardUsageClient {
    private let usageURL = URL(string: "https://dev.meta.ai/usage")!
    private let attempts: Int
    private let pollInterval: Duration

    init(attempts: Int = 60, pollInterval: Duration = .milliseconds(250)) {
        self.attempts = attempts
        self.pollInterval = pollInterval
    }

    func fetchUsage(cookies: [MuseDashboardCookie]) async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // `innerText` depends on layout. A zero-sized, unattached view loads the document but
        // exposes an empty rendered body, so give the off-screen renderer a stable viewport.
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            configuration: configuration
        )
        let cookieStore = configuration.websiteDataStore.httpCookieStore

        for stored in cookies {
            guard let cookie = Self.httpCookie(from: stored) else {
                throw MuseDashboardUsageError.invalidCookie
            }
            await cookieStore.setCookie(cookie)
        }

        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 15
        webView.load(request)

        var lastRenderedText = ""
        var lastUsageText: String?
        for _ in 0..<attempts {
            try Task.checkCancellation()
            if let text = try? await renderedText(in: webView) {
                lastRenderedText = text
                let lowercased = text.lowercased()
                if lowercased.contains("current usage") || lowercased.contains("weekly limit") {
                    lastUsageText = text
                }
                if lowercased.contains("current usage") && lowercased.contains("weekly limit") {
                    return text
                }
            }
            try await Task.sleep(for: pollInterval)
        }

        if let lastUsageText { return lastUsageText }
        let lowercased = lastRenderedText.lowercased()
        let host = webView.url?.host ?? "none"
        let path = webView.url?.path ?? "none"
        AppLog.warn(
            LogTag.plugin("muse"),
            "dashboard page missing quota labels "
                + "(host=\(host), path=\(path), body=\(!lastRenderedText.isEmpty), "
                + "login=\(lowercased.contains("login") || lowercased.contains("log in") || lowercased.contains("sign in")), "
                + "usage=\(lowercased.contains("usage")), current=\(lowercased.contains("current")), "
                + "weekly=\(lowercased.contains("weekly")), browser=\(lowercased.contains("browser")), "
                + "genericError=\(lowercased.contains("something went wrong")))"
        )
        if webView.isLoading { throw MuseDashboardUsageError.timeout }
        throw MuseDashboardUsageError.invalidPage
    }

    private func renderedText(in webView: WKWebView) async throws -> String {
        let result = try await webView.evaluateJavaScript("document.body ? document.body.innerText : ''")
        return result as? String ?? ""
    }

    private static func httpCookie(from cookie: MuseDashboardCookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: cookie.domain,
            .path: cookie.path,
            .secure: cookie.isSecure ? "TRUE" : "FALSE",
            HTTPCookiePropertyKey("HttpOnly"): cookie.isHTTPOnly ? "TRUE" : "FALSE"
        ]
        if let expires = cookie.expires { properties[.expires] = expires }
        if let sameSite = cookie.sameSite { properties[HTTPCookiePropertyKey("SameSite")] = sameSite }
        return HTTPCookie(properties: properties)
    }
}
