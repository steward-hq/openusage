import XCTest
@testable import OpenUsage

final class MuseDashboardSessionStoreTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/tmp/openusage-tests")
    private let now = Date(timeIntervalSince1970: 1_788_710_400)

    func testAbsentStorageStateHasTypedError() {
        let store = makeStore()

        XCTAssertThrowsError(try store.cookies()) { error in
            XCTAssertEqual(error as? MuseDashboardSessionError, .absent)
        }
    }

    func testMalformedStorageStateHasTypedUnreadableError() {
        let store = makeStore(contents: "not json")

        XCTAssertThrowsError(try store.cookies()) { error in
            XCTAssertEqual(error as? MuseDashboardSessionError, .unreadable)
        }
    }

    func testExpiredStorageStateHasTypedError() {
        let store = makeStore(contents: storageState(cookies: [
            cookie(domain: ".meta.ai", expires: now.timeIntervalSince1970 - 1)
        ]))

        XCTAssertThrowsError(try store.cookies()) { error in
            XCTAssertEqual(error as? MuseDashboardSessionError, .expired)
        }
    }

    func testImportsOnlyUnexpiredCookiesValidForDevMetaAI() throws {
        let store = makeStore(contents: storageState(cookies: [
            cookie(name: "valid", value: "safe-fixture", domain: ".meta.ai", expires: now.timeIntervalSince1970 + 3_600),
            cookie(name: "host", value: "host-fixture", domain: "dev.meta.ai", expires: -1),
            cookie(name: "expired", domain: ".meta.ai", expires: now.timeIntervalSince1970 - 1),
            cookie(name: "other", domain: ".example.com", expires: now.timeIntervalSince1970 + 3_600)
        ]))

        let cookies = try store.cookies()

        XCTAssertEqual(cookies.map(\.name), ["valid", "host"])
        XCTAssertEqual(cookies.first?.value, "safe-fixture")
        XCTAssertEqual(cookies.first?.domain, ".meta.ai")
        XCTAssertEqual(cookies.first?.path, "/")
        XCTAssertEqual(cookies.first?.isSecure, true)
        XCTAssertEqual(cookies.first?.isHTTPOnly, true)
        XCTAssertEqual(cookies.first?.sameSite, "Lax")
    }

    private func makeStore(contents: String? = nil) -> MuseDashboardSessionStore {
        let path = home.appendingPathComponent(".config/muse/meta_session.json").path
        return MuseDashboardSessionStore(
            files: FakeFiles(contents.map { [path: $0] } ?? [:]),
            now: { [now] in now },
            homeDirectory: { [home] in home }
        )
    }

    private func storageState(cookies: [[String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["cookies": cookies, "origins": []])
        return String(decoding: data, as: UTF8.self)
    }

    private func cookie(
        name: String = "session",
        value: String = "fixture",
        domain: String,
        expires: Double
    ) -> [String: Any] {
        [
            "name": name,
            "value": value,
            "domain": domain,
            "path": "/",
            "expires": expires,
            "httpOnly": true,
            "secure": true,
            "sameSite": "Lax"
        ]
    }
}
