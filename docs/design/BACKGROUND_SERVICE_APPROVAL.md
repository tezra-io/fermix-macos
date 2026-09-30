# Background service approval as a setup step

**Status:** Implemented on `dev` (2026-09-26); Stage 0 acceptance (§9) pending
**Date:** 2026-09-26
**Supersedes:** the interim card from app 0.2.1 (tezra-io/fermix-macos#12) for the approval causes
**Depends on:** nothing in the engine; no contract, descriptor or method changes
**Lands in:** `dev`, for the next minor release

---

## 1. Summary

macOS decides whether Fermix's background agent may run. When it says "not yet", or the
person has switched Fermix off in Login Items, the app today ends setup
on the "Fermix could not start" card. Since 0.2.1 that card at least leads with "Open Login
Items settings", but it is still a failure screen for something that is not a failure: the
person has one switch to flip, and after flipping it they have to come back and press Try
again.

This design makes approval a step of setup. When macOS holds the background item, the
Starting ladder stays where it is, says what it is waiting for, offers the one button that
opens the right pane, and carries on by itself the moment macOS reports the item enabled.
The same rule, in the same place, answers the Home switch "Run in the background", which
today reaches no sentence at all when macOS refuses.

## 2. What happens today

Two paths register the agent, and neither treats approval as a state it can wait in.

**Setup (`ActivationCoordinator.registerLoginItems`).** It reads the agent's status, calls
`ServiceController.enable(.agent)`, and then classifies:

| macOS answer after `register()` | Cause today (0.2.1) | Card |
| --- | --- | --- |
| `enabled` | none | continues |
| `requiresApproval`, item new to this run | `approvalPending` | Open Login Items settings · Try again · View full log |
| `requiresApproval`, item already waiting | `backgroundItemDisabled` | same |
| `register()` throws, status `requiresApproval` | `backgroundItemDisabled` (0.2.1) | same |
| `register()` throws otherwise, or `notFound` | `registrationFailed` | same |
| `notRegistered` | `backgroundItemDisabled` | same |

The 90-second activation budget starts before registration (`activate(progress:)` computes
the deadline first), so any time a person spends in System Settings would count against the
daemon's own start, if activation waited at all.

**Home (`LifecycleCoordinator.enableBackgroundService`).** The transaction rebuilds the
registration: it unregisters whatever is there, then registers. A throw from `register()` becomes
`LifecycleFailure.registration`, whose `sentence` is nil, so Home shows nothing. An item that
registers into `requiresApproval` is not distinguished from a daemon that never came up: the
verify phase waits for a socket launchd will never create and ends in
`socketNeverAppeared`.

**Other readers.** `UpdateReconcile` already names an item awaiting approval
(`.openRecovery(.registrationNeedsApproval)`). `PermissionLedger` shows the background
service row as "Waiting for your approval" with "Open Login Items settings", read from a
held status that `refresh()` updates off the main thread.

## 3. How macOS behaves

Every decision below rests on these facts. Sources are listed at the end of the section;
where Apple's documentation is silent or contradicts practice, it says so. Anything marked
**verify** is checked on a real Mac in the Stage 0 session (§9) before the design is
accepted.

1. **Four statuses, one of them ambiguous.** `SMAppService.Status` is `notRegistered`,
   `enabled`, `requiresApproval` or `notFound`. The SDK header says `requiresApproval` is
   also returned "if the user revokes consent", so it covers both "not approved yet" and
   "switched off". No public API tells them apart [H]. The app's only second signal is what
   the status was before this attempt registered. `enabled` means "eligible to run", not
   running.
2. **A switched-off item refuses registration, with a misleading error.** The header and the
   documentation say `register()` fails with `kSMErrorLaunchDeniedByUser` (11) [H][REG]. In
   practice macOS throws `SMAppServiceErrorDomain` code 1, "Operation not permitted", and the
   status stays `requiresApproval` [F802443][F779379]. This is also what
   `scripts/dev_e2e.sh` meets on the dev loop, with `sfltool dumpbtm` showing the agent
   disallowed. Code 1 has other causes too (a plist launchd already has loaded, an
   unregister racing a register) [F707482][F768592], so the error code decides nothing: the
   status read after the call does. A new registration of an item the person switched off
   before stays off, because macOS keeps that choice "to preserve user intent" [F707482].
3. **No change notification.** ServiceManagement publishes no callback, notification or
   documented key-value observation for a status change [H]. Apple's advice is to check the
   status when the app launches and when a connection to the helper fails [H][UPD]. On a
   Developer ID build each read is a synchronous XPC round trip of about 70 ms in which
   macOS re-verifies the app (`LoginRegistrations`, measured 2026-09-24), so reads leave the
   main thread and happen only when there is a reason.
4. **The documented way to the pane.** `SMAppService.openSystemSettingsLoginItems()` (macOS
   13 and later) opens the Login Items pane. It takes no argument, so it cannot scroll to a
   section or to Fermix's row [H]. The `x-apple.systempreferences:` URL the app opens today
   is not documented for developers, and DTS calls Apple's undocumented URL schemes
   unsupported [F761314]; in practice the two land in the same place.
5. **Approval starts the job (verify).** Not documented for agents. In a DTS walkthrough the
   job was loaded by launchd once the user allowed it, with no second `register()`
   [F802443], and an SMAppService agent otherwise behaves like any launchd agent, so its
   `RunAtLoad` applies [F750528]. There are reports of `enabled` with a helper that never
   launched [F825110], which is why setup trusts the daemon's socket, not the status, for
   "it is running".
6. **Managed Macs.** The `com.apple.servicemanagement` MDM payload auto-enables and
   auto-allows matching items [DM][PD]. The status the app then sees is not documented;
   `enabled` is implied. The item is listed under Managed Background Apps and the person
   cannot switch it off [L27]. The app still has to call `register()` itself.
7. **The section's name changes with the macOS version.**

   | macOS | Pane | Section with Fermix's switch |
   | --- | --- | --- |
   | 15 | Login Items & Extensions | Allow in the Background [UG] |
   | 26 | Login Items & Extensions | App Background Activity [UG] |
   | 27 | Login Items & Extensions | Background App Activity [L27] |

   The app's floor is macOS 15, so no one label is right for everyone. An in-bundle agent is
   listed under the app's own name, Fermix, with one switch [UPD]. **So the copy names the
   pane and Fermix, never the section.** The 0.2.1 strings, which say "Allow in the
   Background", are wrong on macOS 26 and later and are corrected by this change (§5.6).
8. **Diagnostics.** `sfltool dumpbtm` prints each item's disposition; an item the person
   switched off reads "enabled, disallowed" [TEB][L27]. `sfltool resetbtm` has no per-app
   argument and resets every app's background items and the person's choices on the Mac
   [PD], so it is never part of this gate. (`docs/STAGE0_RUNBOOK.md`'s reset protocol keeps it
   as a commented-out last resort for a registration with no bundle left to withdraw it.)

Sources: [H] `SMAppService.h` and `SMErrors.h` in the macOS 26.5 SDK.
[REG] developer.apple.com/documentation/servicemanagement/smappservice/register().
[UPD] developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos.
[F*n*] Apple Developer Forums thread *n* (developer.apple.com/forums/thread/*n*).
[DM] developer.apple.com/documentation/devicemanagement/servicemanagementmanagedloginitems.
[PD] support.apple.com/guide/deployment/depdca572563.
[UG] the Mac User Guide's Login Items page for each version (support.apple.com/guide/mac-help/mtusr003).
[TEB] theevilbit.github.io/posts/smappservice (third party).
[L27] this Mac, macOS 27.0: the English strings of `LoginItems.appex` and `sfltool dumpbtm`.

## 4. Goals and non-goals

**Goals**

- An item macOS is holding never ends setup. Setup waits on a named step and continues by
  itself once the item is enabled.
- One owner decides what a registration attempt means, for setup and for Home alike.
- The person sees one button, and it opens the right pane through the documented API.
- The daemon's 90-second budget measures the daemon, not the person.
- No registration loop: `register()` is called once per attempt, and waiting is only reading.

**Non-goals**

- Telling "not yet approved" from "switched off" beyond the prior-status signal macOS
  leaves us. The step reads the same either way; only one sentence differs.
- Bringing the window forward when approval lands. macOS restricts an app activating
  itself, and the Fermix window is where the person returns to anyway.
- Any engine, contract or daemon change.

## 5. Design

### 5.1 One owner of what a registration means

`ServiceController` gains the rule that `ActivationCoordinator` and `LifecycleCoordinator`
each half-implement today:

```swift
/// What asking macOS to run the background agent came to.
public enum BackgroundServiceConsent: Equatable, Sendable {
    /// Registered and allowed. launchd runs the agent.
    case enabled
    /// Registered, and macOS is holding it for the person.
    case awaitingApproval(BackgroundApproval)
    /// macOS would not register it, and is not holding it for approval.
    case refused(ServiceRegistrationStatus, underlying: String?)
}

/// `.switchedOff` when the item was already held before this attempt, which is
/// the only sign that the person switched it off rather than has not answered.
public enum BackgroundApproval: Equatable, Sendable { case awaited, switchedOff }

public func requestBackgroundService() -> BackgroundServiceConsent
```

`requestBackgroundService()` reads the status, calls `register()` once, and reads the status
again, whether or not `register()` threw. `requiresApproval` afterwards is
`awaitingApproval`; `enabled` is `enabled`; anything else is `refused`, carrying macOS's
own message where `register()` threw. A throw that leaves the item `enabled` is `enabled`:
the status decides and the error never does (§3.2). Setup and Home's switch both ask
through it, which is what makes the 0.2.1 fix permanent instead of local to setup. (The
restart's plist renewal still calls `register()` directly: it only runs on an item that
was `enabled` a moment earlier, and its refusal already surfaces as a registration
failure.)

`ServiceController` also gains `awaitBackgroundApproval()` (§5.3) and
`openLoginItemsSettings()`, which calls `SMAppService.openSystemSettingsLoginItems()`
through the `LoginItemService` seam. `PermissionLedger.loginItemsPane` and the URL
identifier are deleted; the Permissions row and the setup step both call the one opener.

### 5.2 Setup: approval is a state of the service row

The Starting ladder keeps its four rows. The first row, "Registering the background
service", gains a second state instead of the ladder gaining a fifth row, because a row that
appears only on some Macs is the "row shown for work nobody does" problem the ladder already
avoids.

- `ActivationStage` keeps its four cases. Adding `.awaitingApproval` there would have added
  the fifth row this section rules out: `ActivationPlan.stages` is built from
  `ActivationStage.allCases`. Instead activation reports `ActivationProgress`, which is
  either `.reached(ActivationStage)` or `.awaitingApproval(BackgroundApproval)`, and the
  machine holds the approval beside the stage. The service row keeps its index and state
  (active) and changes only its words.
- `activate(progress:)` asks `requestBackgroundService()`:
  - `enabled`: registers the GUI login item as before, on to `.starting`.
  - `awaitingApproval`: registers the GUI login item, reports `.awaitingApproval` and awaits
    `awaitBackgroundApproval()`. When that returns `enabled`, activation records the
    registration receipt and continues to `.starting`.
  - `refused`: ends with `backgroundItemDisabled` (no item and no error) or
    `registrationFailed`, as today, and registers no GUI login item for a daemon that
    cannot run.
- The 90-second deadline is computed when the daemon step begins, not when activation
  begins. The refusals, the registration and the approval wait come before it.
- While the step is showing, the Starting surface draws a block under the ladder, the way
  Applying draws its restart block: one sentence and one secondary button, "Open Login Items
  settings". The bottom bar keeps Cancel, which cancels the wait like any other part of
  activation and returns to Home.
- The caption "macOS may mention a new background item. That is Fermix." stays. For an
  agent, the "Background Items Added" notification is informational and opens Login Items
  when clicked; macOS shows it once per item and remembers the answer [F802443].

### 5.3 Waiting without polling hard

`awaitBackgroundApproval()` is an async function that returns when the agent's status
leaves `requiresApproval`, and honours task cancellation. It reads the status off the main
thread:

- once when it starts;
- whenever the app becomes active (`NSApplication.didBecomeActiveNotification`), which is
  the moment the person returns from System Settings; Home already re-reads its
  registrations on the same notification;
- and every 3 seconds as a backstop, for a person who flips the switch and never clicks
  back into Fermix.

At about 70 ms a read, the backstop costs a few percent of one core's time while the step
is on screen and nothing otherwise. It never calls `register()`.

It returns the new status, or nil once cancelled. `enabled` continues setup; `notRegistered`
or `notFound` (the item was removed while we waited) ends activation with
`backgroundItemDisabled` or `registrationFailed`. When the schedule is cancelled (Cancel on
the ladder), activation returns the same `timedOut` a cancelled socket wait does, and the
model drops it, as it already drops every outcome of a cancelled activation.

The two moments to read are one seam, `ApprovalReadSchedule`, whose shipped value
`ReturnOrBackstop` races `didBecomeActiveNotification` against the 3-second backstop, so
the tests decide when the person flips the switch without a clock or AppKit.

If Stage 0 finds that approval does not start the job (§3.5), the one addition is a single
`register()` call after `awaitBackgroundApproval()` returns `enabled`, which on an enabled
item asks launchd to load it. It is still one call per approval, never a loop.

### 5.4 Home: the switch waits the same way

`LifecycleCoordinator.enableBackgroundService()` keeps its rebuild (unregister a stale
registration, then register), which exists because of the 2026-09-17 upgrade incident. The
register half becomes `requestBackgroundService()`, and the mutate phase acts on its
answer:

- `enabled`: unchanged, on to verify.
- `awaitingApproval`: the transaction ends with a new outcome,
  `LifecycleOutcome.awaitingApproval`, clears its journal (nothing is half-done: the
  registration is made and macOS is holding it), and does not wait for a socket launchd will
  not create. The registration receipt is left as it was: it is written only for a
  registration macOS allows.
- `refused`: `LifecycleFailure.registration(.registrationFailed)`, which gains a sentence (it
  had none), naming the pane. The unregister half keeps none: its remedy is not a switch.
  The sentence does not say "nothing was changed", because the rebuild has already
  withdrawn the old registration by then.

Home's Attention row is not tied to the transaction. `HomeModel.attention` leads the
daemon's section with "Allow Fermix to run in the background" / "Open Login Items settings"
whenever the registration Home holds reads `requiresApproval`. Home reads it at launch, when
the app becomes active and after every transaction, so the row appears however the item came
to be held: setup, the switch, or switched off in System Settings since (open question 3).
While it is held the daemon cannot answer, so the row replaces the "could not report" row
rather than sitting above it. Home has no status poll, so a registration that moves from
held to allowed also reads the daemon again, queued behind a refresh already running.

Two other callers of the enable transaction discarded its outcome and read "did not throw"
as "restored": the update reconcile's `restoreRegistration()` and the update rollback. The
reconcile now ends a held restore in Recovery with its existing
`.registrationNeedsApproval` reason, without waiting out a verification for an engine that
cannot start, and the rollback keeps its record for that reconcile instead of clearing it.

### 5.5 What changes on the failure card

- `approvalPending` is removed from `BootFailureCause`: an item waiting for approval is now
  a step, never a failure. Its string and the 0.2.1 test cases for it go with it.
- `backgroundItemDisabled` stays for an item macOS unregistered or lost while setup waited,
  and for `notRegistered` after `register()`.
- `registrationFailed` stays, leading with "Open Login Items settings" as in 0.2.1.

### 5.6 Copy

All through `ProductStrings` and `Localizable.strings`, sentence case, no em dashes.

| Key | Text |
| --- | --- |
| `starting.row.awaitingApproval` | Waiting for you to allow Fermix in the background |
| `starting.approval.body` | Open Login Items settings and turn Fermix on. Setup carries on by itself. |
| `starting.approval.bodySwitchedOff` | Fermix is turned off in Login Items. Turn it back on there and setup carries on by itself. |
| `home.attention.backgroundApproval` | Allow Fermix to run in the background |
| `lifecycle.registrationRefused` | macOS refused to register the Fermix background item, so nothing was changed. Open Login Items settings, turn Fermix on, then try again. |
| `bootFailed.cause.backgroundItemDisabled` | Fermix is turned off in Login Items. Your configuration hasn’t been touched, so open Login Items settings, turn Fermix back on, then try again. |
| `bootFailed.cause.registrationFailed` | macOS refused to register the Fermix background item, so nothing was changed. Open Login Items settings, turn Fermix on, then try again. |

No string names the section Fermix's switch sits in, because its name differs between macOS
15, 26 and 27 (§3.7). "Allow in the Background" leaves `ProductCopyRules.properPhrases`,
and the 0.2.1 test that every Login Items sentence contains it is replaced by one that none
does. The button is the existing `permission.action.openLoginItems`, "Open Login Items
settings". The M34 copy deck (§7) and §5.2 and §5.6 of the redlines are updated in the same
change, and so is `scripts/dev_e2e.sh`'s refusal, which names the old section too.

## 6. Accessibility

- The service row announces its change of state through the existing ladder announcer
  ("Waiting for you to allow Fermix in the background, in progress", then "Registering the
  background service, done"). The announcer compared row states only, and the row's state
  does not change when it starts waiting, so it now compares the whole row.
- A Home enable that ends held for approval is announced with the Attention row's title,
  which is what is left for the person to do.
- The approval block's sentence is read before its button; the button is reachable with Tab
  and Space like every in-window secondary button.
- Nothing time-limits the step, so nobody is hurried while working in System Settings.

## 7. Tests

All in `FermixAppCoreTests`, all through doubles; no test reads or changes this Mac's
login items.

- `ServiceControllerTests`: `requestBackgroundService()` for each row of the §2 table,
  including a throw with the status left at `requiresApproval` and a throw that leaves it
  `enabled`, and exactly one `register()` call per request; the wait reads until the status
  moves, never registers, and answers nil once cancelled; the shipped schedule ends as soon
  as its task is cancelled; the opener goes through the seam.
- `ActivationCoordinatorTests`: a scripted read schedule during which the person answers.
  Activation reports `.awaitingApproval(.awaited)` or `(.switchedOff)`, then `.starting`,
  and activates with one `register()`; four minutes of waiting still activates, and the
  daemon then gets its whole 90 seconds; cancelling ends without asking the daemon; an item
  removed or lost while waiting ends with `backgroundItemDisabled` or `registrationFailed`.
- `OnboardingMachineTests` and `DesignComponentTests`: the wait keeps four rows, changes the
  service row's words, clears on every exit, and is announced both ways.
- `OnboardingModelTests`: the Starting surface shows the approval block only in that stage,
  with the sentence for each kind of hold; its button opens Login Items through the seam and
  never through a URL; Cancel leaves for Home.
- `LifecycleCoordinatorTests`: enabling into approval ends with `awaitingApproval`, writes
  no failed journal, waits for no socket and leaves the receipt; rebuilding a switched-off
  item ends the same way; a refused registration has a sentence and a refused unregister
  does not.
- `HomeSurfaceTests`: a held item leads Attention, replacing the unreachable row and leading
  the daemon's own rows, and goes once macOS allows it; its action opens Login Items.
- `UpdateReconcileTests`: a restore held for approval ends in Recovery with
  `registrationNeedsApproval` and no verification wait.
- `ProductStringsTests`: the new strings pass the copy rules and name the pane and Fermix,
  never the section.
- `FixtureConfigurationTests`: the `assistant/approval` fixture start opens Starting on a
  Mac that holds the agent as a first install does, so the step can be looked at with
  `--fixture --fixture-start assistant/approval`.

## 8. Rollout

App-only. It landed on `dev` after `main` (which carries 0.2.1) was merged into it, together
with the copy commit of tezra-io/fermix-macos#14 (0.2.2, build 7), and ships in the next
minor release with a build number of 8 or more. The engine pin, the vendored
contracts and `Product.json`'s identity are untouched. Nothing about an existing
registration changes: an account that is already enabled never sees the step.

## 9. Stage 0 acceptance

Added to `docs/STAGE0_RUNBOOK.md` as section 9, on the staged release bundle:

1. With Fermix installed and set up, switch it off in Login Items & Extensions. Confirm
   `sfltool dumpbtm` shows the agent "enabled, disallowed".
2. Run setup again. The Starting ladder stops on "Waiting for you to allow Fermix in the
   background", with no failure card.
3. Press "Open Login Items settings". System Settings opens on Login Items.
4. Switch Fermix on, and do not click back into Fermix. Within a few seconds the ladder
   moves on and setup finishes. This is the check for §3.5.
5. Repeat from Home: switch Fermix off in System Settings, then turn on "Run in the
   background". Home shows the attention row; switching Fermix on in System Settings brings
   the daemon up.
6. Never run `sfltool resetbtm`.

## 10. Open questions

1. §3.5: does approval start the agent without another `register()`? Stage 0 answers it,
   and §5.3 has the change if it does not.
2. The 3-second backstop: short enough to feel immediate, long enough to cost nothing.
   Worth measuring the read cost on the release bundle before fixing the number.
3. ~~Should Home's attention row also appear on launch for an account whose item was
   switched off after setup?~~ Yes, and it does by construction: the row is read from the
   registration Home holds, not from a transaction's outcome (§5.4).
4. macOS 26 added a prompt when an app's background activity carries on after the app quits
   (about 60 seconds, undocumented threshold) [PD][F799162]. Whether an SMAppService agent
   like Fermix's triggers it is undocumented. Stage 0 should quit the app and wait, and if
   it does appear, its wording decides whether the Starting caption needs a second line.
