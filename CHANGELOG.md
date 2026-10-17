# Changelog

The release notes, kept as the work lands. One line per change a person sees or does, under Unreleased until the release chore PR moves it under its version.

## Unreleased

- Chat: a voice note from your phone now plays right in the Mac chat, with play, pause, a track to move along and its time, and its transcript still under it. Pictures and files from your phone, and the pictures Fermix sent to it, show as tiles under their message and open inside Fermix as the files a reply names do, and a link your phone shared shows its picture in its card. A voice note's transcript and a link's preview appear as soon as Fermix has them, and a voice note or file Fermix no longer keeps says Not available.
- Channels: among your phones’ settings, a line under Reach from anywhere says whether a paired phone can reach Fermix from any network yet. Until a build carries it, the line says so, and your phone keeps connecting over your home network or Tailscale.
- Channels: your phones’ settings are shorter. The port, the address Fermix listens on and the local-network announcement, which most people never change, sit under a closed Advanced at the end.
- Chat: a voice note is one lean line: its play button, a waveform drawn from its own sound that fills in as it plays and that you click or drag to move along, and its time, with the transcript under it. A sound file Fermix names shows the same waveform under its name. A voice note Fermix no longer keeps says Not available as soon as it shows, rather than when you press play.
- Chat: code in a reply reads as code. Each block sits on its own soft panel with its language named above it, such as Shell, Python or TypeScript, quietly coloured so comments, strings and keywords stand apart, and a long line wraps so a whole command shows at once. Copy appears when you point at a block and takes its exact text. A short bit of code inside a sentence sits on a faint fill.
- Chat: lists, numbered steps, tables and quotes in a reply read as what they are. A list keeps its bullets or numbers with each item indented under its own, a table sits on a soft panel with its columns lined up, scrolling sideways when it is wide and copied as a table, and a quote has a thin bar beside it. A long reply also takes less work to draw while Fermix is still writing it.
- Chat: when Fermix recommends places it found, they show under its reply on a map with a numbered pin for each and as cards in a row that scrolls sideways, each with its rating, price, kind, today's hours and distance. A card's menu opens the place in Maps or its website, or copies its address. The reply still links every place, so nothing is lost where cards are not shown.
- Chat: the places Fermix finds come from Apple Maps, with no key to set up, and clicking a place's card or pin shows Apple's own card for it right in the chat, with its photos, hours and whether it is open now. Its close button, Escape or a click elsewhere puts it away, and Open in Maps in a card's menu still takes you to Maps. Web search settings can switch place search to Brave instead, whose places open in Maps when clicked.
- Chat: the links under a reply are cards the size of a place's, each with the page's picture, title and site. Once a reply is written, Fermix reads up to four of the pages it links from this Mac, whether or not a phone is paired, and never the pages a place card already stands for. A page it could not read shows its site's initial and the words of its address, never a raw path. A link to a page on a recommended place's own website, such as its menu, is left to that place's card.
- Voice: you can talk with Fermix through Grok from SpaceXAI by choosing it as the voice model in Voice settings and adding a SpaceXAI API key. Grok hands its tasks to Fermix as GPT-Live does, and a reply you talk over stops at what you actually heard. The reminder to add a voice key now names the provider it needs, OpenAI or SpaceXAI.

## 0.5.0 (2026-10-14)

- Runs the Fermix engine 0.15.0, which turns the phone channel on and off at once with no restart and has it on for a new install, pairs only a phone that proves its secure hardware, offers Claude Haiku 5.5, hears a GPT-Live call from the moment it starts, transcribes the phone's voice notes, and gives the model every attachment you send, a GIF, a video, a PDF or a text file among them, where it used to see only pictures and voice notes.
- Chat: during a voice call, a message you type can simply feed the call. Fermix no longer has to write a short reply to it, and the chat stops showing it as thinking when no reply comes.
- Chat: the files a reply names show under it in a row that scrolls sideways, with a trackpad, Shift and the scroll wheel, the arrows that appear at its edges, or the Left and Right keys once it is clicked: a screenshot, a video's still frame, a PDF's first page or a document fills its own thumbnail, and a link or a file with nothing to preview is a compact card. A line that only names something already shown is left out of the text, while links inside a sentence stay. Nothing is fetched from the internet to draw a card, and a file outside your Fermix home shows only its icon until you open it.
- Chat: a voice note you send from your phone shows in the Mac chat as a voice note, with its transcript under it once Fermix has it, and a sound file Fermix names plays right where it is. Your place in the conversation stays put as previews arrive and messages fill in.
- Channels: you can pair your Android phone from the Mac, with no Terminal. The Phone row's Pair a phone… turns the phone channel on and restarts Fermix where it needs to, saying so first, then shows a code to scan, with the link itself behind Can’t scan the code? for a phone or an emulator that cannot scan it, and asks you to approve only when both screens show the same six digits. Once a phone is paired the row names it, and Change… lists your phones, forgets one or pairs another. The last setup screen offers Pair your Android phone as an optional step.
- Browser pane: videos and sounds play in the pane, and documents, spreadsheets, presentations and CSV files open there as macOS previews them, with Open in their own app beside. A file outside your Fermix home is asked about before it opens. Picture tabs zoom with Command-plus, Command-minus, Command-0 and Command-9.
- Voice: a call keeps hearing you when macOS reconfigures the microphone during it, which it can do on the first call after Fermix starts.
- Voice: the first call after Fermix starts no longer freezes the window for a moment while the microphone gets ready, so the pet appears in the chat as soon as you click.
- Pet: a call begun from the pet resting in the chat goes straight into the call without hatching again. The pet hatches only when it first appears.
- Pet: during a call the pet takes its listening pose only while Fermix can hear you, which is from the moment the call starts, and rests once the call is ending instead of looking like it is still listening.
- Pet: the stop button on the pet's dock ends a call and closes the chat's box in one press, as the chat's call button does, and only a click on the pet leaves it resting there. Neither is red any more: the call button's phone fills while a call is up.
- The macOS floor stays at 15.0.

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
