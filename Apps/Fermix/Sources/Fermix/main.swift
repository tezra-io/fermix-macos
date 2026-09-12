import FermixAppCore
import FermixSparkle
import Foundation

// Top-level code in `main.swift` runs on the main thread before any other work
// exists, which is exactly the main actor's context; saying so is what lets the
// whole app body stay isolated.
//
// The updater is constructed here and nowhere else. It is the only object the
// executable owns rather than the core library, because it is the only one that
// links Sparkle: M34 §6 requires that the daemon and `FermixAgent` never load
// it, and both of those link `FermixAppCore`. `main` never returns, so the one
// controller lives for the whole GUI process, which is what a scheduled check
// needs.
MainActor.assumeIsolated {
    FermixApp.main(updater: SparkleUpdater())
}
