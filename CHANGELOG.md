# Changelog

The release notes, kept as the work lands. One line per change a person sees or does, under Unreleased until the release chore PR moves it under its version.

## Unreleased

- Voice: a call keeps hearing you when macOS reconfigures the microphone during it, which it can do on the first call after Fermix starts.
- Pet: a call begun from the pet resting in the chat goes straight into the call without hatching again. The pet hatches only when it first appears.
- Voice: the first call after Fermix starts no longer freezes the window for a moment while the microphone gets ready, so the pet appears in the chat as soon as you click.
- Pet: during a call the pet takes its listening pose only once Fermix can hear you, so while the call is still connecting, or once it is ending, the pet rests instead of looking like it is listening.
- Pet: the stop button on the pet's dock ends a call and closes the chat's box in one press, as the chat's call button does, and only a click on the pet leaves it resting there. Neither is red any more: the call button's phone fills while a call is up.

## 0.4.0 (2026-10-08)

- Runs the Fermix engine 0.14.0, which serves the iMessage channel and the ChatGPT sign-in for OpenAI Codex that the app now shows, offers Mistral Large 4, and keeps a GPT-Live call's work in the chat, where a task still running when the call ends finishes instead of being dropped.
- Chat: a file a reply names, such as a screenshot or a report the agent saved, is a link. Pictures, PDFs, text and HTML open read only in a file tab of the browser, with a page's scripts off and nothing loaded from the internet; documents such as Word files, Pages files and spreadsheets open in their own app; and anything else, an app among them, is only shown in Finder, so a click never runs anything.
- Channels: turning iMessage on installs Fermix Messages first, and if the install fails the switch stays off with the reason under it. The iMessage row then names the first thing still missing until it reads Connected; while that is a grant or your confirmation of who Fermix may message, it reads "Grant in Permissions" or "Confirm in Permissions", and those words open the Permissions pane.
- Permissions: once iMessage is on, Messages data, Messages automation and Who Fermix may message each have a row with the one button that grants or confirms it, and the rows catch up when you come back from System Settings.
- Pet: a click on the pet begins or ends the call wherever the pet is shown, the pet stays in the chat's box after a call until you close it, and the pet's dock ends a call with a stop button. While a call is up, that stop and the chat's call button, now a hang-up, turn red, so the way to end the call is easy to find.
- Channels: iMessage and Phone show their own marks instead of the generic channel symbol.
- Channels: the Phone row says it is available with the phone app and cannot be switched on until that app ships.
- Channels: iMessage joins the Channels pane on a Mac, with the account choice, your handle and the guest list.
- Browser: a website's upload field in your own tab opens the Mac's file chooser, so you can attach a file or a folder. A task's tab never opens it.
- Browser: a link to another app, such as an email address, asks before that app opens when you click it in your own tab, and a task's tab never opens another app.
- Browser: a page on this Mac, such as a local development server, opens in the browser instead of a blank page.
- Voice: a second click while a call is connecting calls it off, and hanging up waits for the call to settle, so the next call never shows the last one's task or cost.
- Voice: the caption line shows the running words of whoever last spoke, a task shows the daemon's summary of the work, and a failed call says why in plain words with the provider's own explanation.
- Pet: the call's cost stays on the page after the call ends.
- Voice: a call can be begun and ended from the View menu and the menu bar, and when voice is not set up the call control says so and opens its settings instead of starting a call that fails.
- Browser: a file a website offers in your own tab can be saved where you choose through the Mac's save panel.
- Providers: OpenAI Codex connects with Continue with ChatGPT and runs on your ChatGPT plan, with no API key and no Codex command line tool. Its details show the account you signed in with, that your plan is in use, and Manage usage, which opens your ChatGPT usage settings. Signing out disconnects Fermix from your ChatGPT account, not only from this Mac.
- Providers: Import Codex sign-in and Fast mode are gone, because OpenAI Codex now signs in only with ChatGPT.
- Sign-in: the browser stays in front while you sign in, because the waiting sheet now opens it after coming up instead of appearing over it.
- Chat: a call button at the top right begins and ends a voice call, and while the call runs the pet floats there with its mute, interrupt and end controls, staying to say why if the call fails.
- The macOS floor stays at 15.0.

## 0.3.0 (2026-09-30)

- Chat: one conversation shared with the phone, with a greeting on the empty state, search, approval cards, and replies that follow a sent message to the bottom.
- Chat: headings and fenced code in a reply are drawn as text and code, not as their markdown marks.
- Browser: a built-in WebKit pane that the agent's tasks drive, opening beside the chat and widening the window, with the page taking the width the chat cannot use.
- Browser: a task that runs visibly shows its tab in the pane while it runs, and a screenshot or PDF the agent takes lands where the engine names it.
- Settings: a provider's detail leads with how it signs in, and the key field appears only when an API key is the choice.
- Settings: a model field matches what you type against the provider's own model list in its one dropdown.
- Settings: the Browser and Secrets panes the engine publishes.
- Pet: a reaction for every voice mode and a livelier idle.
- Runs the Fermix engine 0.12.1, which names the browser pane in its schema and keeps its background workers running through a slow database.
- The macOS floor stays at 15.0.
