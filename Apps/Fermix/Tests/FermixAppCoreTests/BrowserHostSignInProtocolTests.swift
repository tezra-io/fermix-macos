import Foundation
import Testing

@testable import FermixAppCore

/// `browser_host` protocol 2's two sign-in requests, their answers and the
/// seven reasons, against the engine's own golden lines (engine
/// `priv/browser_host/fixtures`, protocol 2), held here so the shapes are
/// proven before the vendored copy moves to protocol 2.
@Suite("Browser host sign-in protocol")
struct BrowserHostSignInProtocolTests {
    @Test("this build declares protocol 2 inside a window of 1 to 2")
    func declaresProtocolTwo() {
        #expect(BrowserHostProtocol.version == 2)
        #expect(BrowserHostProtocol.supportedWindow == BrowserHostVersionWindow(minimum: 1, maximum: 2))
        #expect(BrowserHostProtocol.supportedWindow.contains(1))
    }

    @Test("page.login_for and both page.sign_in shapes decode into their typed fields")
    func requestsDecode() throws {
        let loginFor = #"{"id":28,"type":"page.login_for","tab_id":"t1","site":"example.com"}"#
        let signIn = #"""
            {"id":29,"type":"page.sign_in","tab_id":"t1","site":"example.com","login_site":"example.com","username_ref":11,"password_ref":12,"observe":false}
            """#
        let usernameOnly = #"""
            {"id":30,"type":"page.sign_in","tab_id":"t1","site":"www.example.com","login_site":"example.com","username_ref":11,"observe":true,"snapshot":{"mode":"interactive","max_chars":50000,"depth":5}}
            """#

        #expect(try Self.request(loginFor) == .pageLoginFor(id: 28, BrowserHostPageLoginForRequest(tabId: "t1", site: "example.com")))
        #expect(try Self.request(signIn) == .pageSignIn(id: 29, BrowserHostPageSignInRequest(
            tabId: "t1", site: "example.com", loginSite: "example.com", observe: false,
            usernameRef: 11, passwordRef: 12, snapshot: nil
        )))
        #expect(try Self.request(usernameOnly) == .pageSignIn(id: 30, BrowserHostPageSignInRequest(
            tabId: "t1", site: "www.example.com", loginSite: "example.com", observe: true,
            usernameRef: 11, passwordRef: nil,
            snapshot: BrowserHostSnapshotOptions(mode: .interactive, maxChars: 50_000, depth: 5)
        )))
        #expect(try Self.request(loginFor).wireType == "page.login_for")
        #expect(try Self.request(signIn).wireType == "page.sign_in")
    }

    @Test("a sign-in ref that is not an integer, or a missing login_site, is refused by its name")
    func requestFieldsAreChecked() {
        let textRef = #"{"id":29,"type":"page.sign_in","tab_id":"t1","site":"a.com","login_site":"a.com","password_ref":"12","observe":false}"#
        let noLoginSite = #"{"id":29,"type":"page.sign_in","tab_id":"t1","site":"a.com","password_ref":12,"observe":false}"#

        #expect(throws: BrowserHostDecodeFailure.invalidField("password_ref")) {
            _ = try BrowserHostInbound.decode(Data(textRef.utf8))
        }
        #expect(throws: BrowserHostDecodeFailure.missingField("login_site")) {
            _ = try BrowserHostInbound.decode(Data(noLoginSite.utf8))
        }
    }

    @Test("both answers encode as the engine's golden lines")
    func answersEncode() throws {
        let cases: [(BrowserHostResponse, String)] = [
            (
                BrowserHostResponse(id: 28, result: .pageLoginFor(loginSite: "example.com", username: "person@example.com")),
                #"{"id":28,"ok":true,"result":{"login_site":"example.com","username":"person@example.com"}}"#
            ),
            (
                BrowserHostResponse(id: 29, result: .pageSignIn(BrowserHostSignInResult(
                    url: "https://example.com/login", title: "Sign in", filled: ["username", "password"]
                ))),
                #"{"id":29,"ok":true,"result":{"url":"https://example.com/login","title":"Sign in","filled":["username","password"]}}"#
            )
        ]

        for (response, golden) in cases {
            #expect(try BrowserHostFixtures.sameObject(response.line(), Data(golden.utf8)), "id \(response.id)")
        }
    }

    @Test("the seven protocol 2 reasons are spelled as the engine spells them")
    func reasonsSpelled() throws {
        let reasons: [BrowserHostErrorReason] = [
            .signInInsecurePage, .signInWrongSite, .signInNoLogin, .signInField,
            .signInPageMoved, .signInStoreUnavailable, .secretOnScreen
        ]

        #expect(reasons.map(\.rawValue) == [
            "sign_in_insecure_page", "sign_in_wrong_site", "sign_in_no_login", "sign_in_field",
            "sign_in_page_moved", "sign_in_store_unavailable", "secret_on_screen"
        ])
        let refusal = BrowserHostResponse(id: 8, error: BrowserHostError(reason: .secretOnScreen, message: "a filled password shows as text on the page"))
        let golden = #"{"id":8,"ok":false,"error":{"reason":"secret_on_screen","message":"a filled password shows as text on the page"}}"#
        #expect(try BrowserHostFixtures.sameObject(refusal.line(), Data(golden.utf8)))
    }

    private static func request(_ line: String) throws -> BrowserHostRequest {
        guard case .request(let request) = try BrowserHostInbound.decode(Data(line.utf8)) else {
            throw BrowserHostFixtureDefect.recordIsNotAnObject(file: "inline", line: 1)
        }
        return request
    }
}
