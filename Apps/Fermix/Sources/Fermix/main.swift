import FermixAppCore
import Foundation

// Top-level code in `main.swift` runs on the main thread before any other work
// exists, which is exactly the main actor's context; saying so is what lets the
// whole app body stay isolated.
MainActor.assumeIsolated {
    FermixApp.main()
}
