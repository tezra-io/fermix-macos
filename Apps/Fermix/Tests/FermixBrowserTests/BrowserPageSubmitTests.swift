import FermixAppCore
import Foundation
import Testing

@testable import FermixBrowser

/// `act` `kind=submit` on a real web view: it sends the form the ref belongs
/// to, by the field's own form or the closest form around it, and a ref in no
/// form sends nothing. The engine submits right after a fill, on the first
/// filled field, so a login or a checkout with no form of its own must never
/// send the page's first form, a search box in its header say.
@MainActor
@Suite("Browser page submit", .serialized)
struct BrowserPageSubmitTests {
    private static let address = "https://shop.example.com/checkout"
    /// A header search form first, a sign-in form with no button, and a
    /// payment area in no form at all. The page records which form was sent
    /// and keeps it from leaving.
    private static let page = """
        <!doctype html><html><head><title>Checkout</title></head><body>
        <form id="search" role="search"><input type="search" aria-label="Search"></form>
        <form id="signin"><input type="email" aria-label="Email"><a href="#help">Help</a></form>
        <div id="pay"><input aria-label="Card number"><div role="button">Pay</div></div>
        <script>
          document.addEventListener("submit", (event) => {
            event.preventDefault();
            window.submitted = event.target.id;
          }, true);
        </script>
        </body></html>
        """

    @Test("a submit on a field in no form answers no_form and sends nothing, though the page has a form")
    func fieldInNoFormSendsNothing() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(Self.page, at: Self.address)
        let card = try await harness.ref(named: "Card number")

        await #expect(throws: BrowserPageDriveError.noForm(card)) {
            _ = try await harness.page.act(.submit(ref: card), observing: nil)
        }
        #expect(try await harness.pageString("window.submitted ?? 'nothing'") == "nothing", "the header search was not sent")
    }

    @Test("a submit on a field sends the field's own form, not the page's first")
    func fieldSendsItsOwnForm() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(Self.page, at: Self.address)
        let email = try await harness.ref(named: "Email")

        let outcome = try await harness.page.act(.submit(ref: email), observing: nil)

        #expect(outcome.submitted == "form.requestSubmit()")
        #expect(try await harness.pageString("window.submitted ?? 'nothing'") == "signin")
    }

    @Test("a submit on an element inside a form that is none of its fields sends that form")
    func elementInsideAFormSendsIt() async throws {
        let harness = BrowserPageHarness()
        try await harness.load(Self.page, at: Self.address)
        let help = try await harness.ref(named: "Help")

        _ = try await harness.page.act(.submit(ref: help), observing: nil)

        #expect(try await harness.pageString("window.submitted ?? 'nothing'") == "signin")
    }
}

private extension BrowserPageHarness {
    /// The ref of the first node named `name`, from the page script's own snapshot.
    func ref(named name: String) async throws -> Int {
        let snapshot = try await page.snapshot(BrowserSnapshotRequest(mode: .full, maxChars: 200_000, depth: 200))
        return try #require(snapshot.nodes.first { $0.name == name && $0.ref != nil }?.ref)
    }
}
