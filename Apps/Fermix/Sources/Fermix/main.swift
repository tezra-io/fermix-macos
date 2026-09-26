import FermixAppCore
import FermixRive
import FermixSparkle
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
// links the Rive runtime, which the agent must not load either.
MainActor.assumeIsolated {
    FermixApp.main(updater: SparkleUpdater(), mascot: RiveMascotRenderer())
}
