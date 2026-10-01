# Changelog

The release notes, kept as the work lands. One line per change a person sees or does, under Unreleased until the release chore PR moves it under its version.

## Unreleased

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
