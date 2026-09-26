# Background service approval as a setup step

**Status:** Draft (design review pending)
**Date:** 2026-09-26
**Supersedes:** the interim card from app 0.2.1 (tezra-io/fermix-macos#12) for the approval causes
**Depends on:** nothing in the engine; no contract, descriptor or method changes
**Lands in:** `dev`, for the next minor release

---

## 1. Summary

macOS decides whether Fermix's background agent may run. When it says "not yet", or the
person has switched Fermix off under **Allow in the Background**, the app today ends setup
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

Every decision below rests on these facts. Each one names its source; anything marked
**verify** is checked on a real Mac in the Stage 0 session (§9) before the design is
accepted.

1. **Four statuses, one of them ambiguous.** `SMAppService.Status` is `notRegistered`,
   `enabled`, `requiresApproval` or `notFound`. `requiresApproval` covers both "the person
   has not approved it yet" and "the person switched it off"; no API tells them apart. The
   app's only second signal is what the status was before this run registered.
2. **A switched-off item refuses registration.** `register()` on an agent the person has
   switched off throws "Operation not permitted", and the status stays `requiresApproval`.
   This is what `scripts/dev_e2e.sh` detects on the dev loop (`sfltool dumpbtm` shows the
   agent `disallowed`). It is also why 0.2.1 reads the status after a throw.
3. **No change notification.** ServiceManagement publishes no callback or notification when
   a status changes. The app has to read `status` again. On a Developer ID build each read is
   a synchronous XPC round trip of about 70 ms in which macOS re-verifies the app
   (`LoginRegistrations`, measured 2026-09-24), so reads leave the main thread and happen
   only when there is a reason.
4. **The documented way to the pane.** `SMAppService.openSystemSettingsLoginItems()` (macOS
   13 and later) opens Login Items. The app currently opens the undocumented
   `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` URL instead.
5. **Approval starts the job (verify).** When the person switches the item on, launchd loads
   it, and the agent's `RunAtLoad` starts the daemon without the app calling `register()`
   again. If Stage 0 shows otherwise, §5.3 has the one change it needs.
6. **Managed Macs.** A login item managed by MDM (`com.apple.servicemanagement`) reports
   `enabled` and cannot be switched off by the person, so it never reaches this step.
7. **Where the switch is.** macOS 15 and later: System Settings > General > Login Items &
   Extensions > Allow in the Background. macOS 13 and 14 call the pane Login Items, with the
   same section. An in-bundle agent is listed under the app's name, Fermix. The copy names
   "Login Items settings" and "Allow in the Background", which hold on every supported
   version (the floor is macOS 15).
8. **Diagnostics.** `sfltool dumpbtm` prints each item's disposition (allowed or
   disallowed, enabled or disabled). `sfltool resetbtm` resets every app's background items
   on the Mac and is never part of a runbook.

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
    /// Registered, and macOS is holding it for the person. `wasWaiting` is true
    /// when it was already held before this attempt, which is the only sign
    /// that the person switched it off rather than has not answered yet.
    case awaitingApproval(wasWaiting: Bool)
    /// macOS would not register it, and is not holding it for approval.
    case refused(ServiceRegistrationStatus, underlying: String?)
}

public func requestBackgroundService() -> BackgroundServiceConsent
```

`requestBackgroundService()` reads the status, calls `register()` once, and reads the status
again, whether or not `register()` threw. `requiresApproval` afterwards is
`awaitingApproval`; `enabled` is `enabled`; anything else is `refused`. It is the only place
in the app that interprets a thrown registration, which is what makes the 0.2.1 fix
permanent instead of local to setup.

`ServiceController` also gains `awaitBackgroundApproval()` (§5.3) and
`openLoginItemsSettings()`, which calls `SMAppService.openSystemSettingsLoginItems()`
through the `LoginItemService` seam. `PermissionLedger.loginItemsPane` and the URL
identifier are deleted; the Permissions row and the setup step both call the one opener.

### 5.2 Setup: approval is a state of the service row

The Starting ladder keeps its four rows. The first row, "Registering the background
service", gains a second state instead of the ladder gaining a fifth row, because a row that
appears only on some Macs is the "row shown for work nobody does" problem the ladder already
avoids.

- `ActivationStage` gains `.awaitingApproval`, which draws on the service row's index with
  its own title and an active marker.
- `activate(progress:)` asks `requestBackgroundService()`:
  - `enabled`: unchanged, on to `.starting`.
  - `awaitingApproval`: reports `.awaitingApproval` and awaits `awaitBackgroundApproval()`.
    When that returns `enabled`, activation records the registration receipt and continues
    to `.starting`.
  - `refused`: ends with `registrationFailed` or `backgroundItemDisabled`, as today.
- The 90-second deadline is computed when the daemon step begins, not when activation
  begins. The refusals, the registration and the approval wait come before it.
- While the step is showing, the Starting surface draws a block under the ladder, the way
  Applying draws its restart block: one sentence and one secondary button, "Open Login Items
  settings". The bottom bar keeps Cancel, which cancels the wait like any other part of
  activation and returns to Home.
- The caption "macOS may mention a new background item. That is Fermix." stays; it is what
  the person sees before macOS asks.

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

It returns the new status. `enabled` continues setup; `notRegistered` or `notFound` (the
item was removed while we waited) ends activation with `backgroundItemDisabled` or
`registrationFailed`.

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
  not create. Home's attention section shows "Allow Fermix to run in the background" with
  "Open Login Items settings". Home already re-reads its registrations when the app becomes
  active, so the switch and the row update when the person comes back, and the next status
  poll finds the daemon that launchd started.
- `refused`: `LifecycleFailure.registration`, which gains a sentence (it has none today),
  naming the switch.

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
| `starting.approval.body` | Turn Fermix on under Allow in the Background in Login Items settings. Setup carries on by itself. |
| `starting.approval.bodySwitchedOff` | Fermix is turned off under Allow in the Background. Turn it on in Login Items settings and setup carries on by itself. |
| `home.attention.backgroundApproval` | Allow Fermix to run in the background |
| `lifecycle.registrationRefused` | macOS refused to register the Fermix background item, so nothing was changed. Open Login Items settings, allow Fermix under Allow in the Background, then try again. |

The button is the existing `permission.action.openLoginItems`, "Open Login Items settings".
The M34 copy deck (§7) and §5.2 and §5.6 of the redlines are updated in the same change.

## 6. Accessibility

- The service row announces its change of state through the existing ladder announcer
  ("Waiting for you to allow Fermix in the background", then "Registering the background
  service, done").
- The approval block's sentence is read before its button; the button is reachable with Tab
  and Space like every in-window secondary button.
- Nothing time-limits the step, so nobody is hurried while working in System Settings.

## 7. Tests

All in `FermixAppCoreTests`, all through doubles; no test reads or changes this Mac's
login items.

- `ServiceControllerTests`: `requestBackgroundService()` for each row of the §2 table,
  including a throw with the status left at `requiresApproval`, and exactly one `register()`
  call per request.
- `ActivationCoordinatorTests`: a login-item double whose status flips to `enabled` on its
  Nth read. Activation reports `.awaitingApproval`, then `.starting`, and activates; the
  deadline starts after the flip (a clock that has passed 90 seconds while waiting still
  activates); cancelling during the wait returns no outcome; an item removed while waiting
  ends with `backgroundItemDisabled`.
- `OnboardingModelTests`: the Starting surface shows the approval block only in that stage;
  its button opens Login Items through the recorded opener; Cancel leaves for Home.
- `LifecycleCoordinatorTests`: enabling into approval ends with `awaitingApproval`, writes
  no failed journal, and waits for no socket; a refused registration has a sentence.
- `ProductStringsTests`: the new strings pass the copy rules.

## 8. Rollout

App-only. It lands on `dev` after `main` (which carries 0.2.1) is merged into it, and ships
in the next minor release with a build number above 6. The engine pin, the vendored
contracts and `Product.json`'s identity are untouched. Nothing about an existing
registration changes: an account that is already enabled never sees the step.

## 9. Stage 0 acceptance

Added to `docs/STAGE0_RUNBOOK.md`, on the staged release bundle:

1. With Fermix installed and set up, switch it off under Allow in the Background. Confirm
   `sfltool dumpbtm` shows the agent disallowed.
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
3. Should Home's attention row also appear on launch for an account whose item was switched
   off after setup? `PermissionLedger` already shows it under Permissions; Home showing it
   too would make "Fermix isn't running" explain itself.
