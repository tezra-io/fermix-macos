import FermixAppCore
import FermixBrowser
import FermixRive
import FermixSparkle
import FermixViewers
import Foundation

// Top-level code in `main.swift` runs on the main thread before any other work
// exists, which is exactly the main actor's context; saying so is what lets the
// whole app body stay isolated.
//
// The updater is constructed here and nowhere else. The executable owns it
// rather than the core library because it links Sparkle: M34 §6 requires that
// the daemon and `FermixAgent` never load it, and both of those link
// `FermixAppCore`. `main` never returns, so the one
// controller lives for the whole GUI process, which is what a scheduled check
// needs.
//
// The mascot renderer is handed in the same way and for the same reason: it
// links the Rive runtime, which the agent must not load either. So is the
// browser pane's engine, which links WebKit; it arrives as a factory because
// it is built over the website profile on the pane's first tab. So are the
// pane's viewers and the chat's media reader, which link AVKit, Quick Look and
// MapKit.
//
// Whether the pane's pages offer Web Inspector is read here, once, from this
// process's signature: the inspector reads a filled password straight out of
// the page, so a build that can hold website logins never offers it (M84 §7).
MainActor.assumeIsolated {
    let inspectable = LoginStoreSelection.allowsWebInspector(grantedGroups: LoginStoreSelection.grantedAccessGroups())
    FermixApp.main(
        updater: SparkleUpdater(),
        mascot: RiveMascotRenderer(),
        browser: { WebKitBrowserEngine(websiteProfile: $0, inspectable: inspectable) },
        viewers: SystemBrowserViewers(),
        mediaReader: SystemMediaReader()
    )
}
