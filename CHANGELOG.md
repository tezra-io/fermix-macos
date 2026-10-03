# Changelog

The release notes, kept as the work lands. One line per change a person sees or does, under Unreleased until the release chore PR moves it under its version.

## Unreleased

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
