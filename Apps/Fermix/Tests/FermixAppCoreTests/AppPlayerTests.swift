import CoreMedia
import Foundation
import Testing

@testable import FermixAppCore

/// The app's one player (M66 §3.4): one thing at a time, read from the
/// player's own state, and every stop. Over a fake engine, so no test opens
/// an audio device.
@Suite("App player")
@MainActor
struct AppPlayerTests {
    static let voice = URL(fileURLWithPath: "/Users/Shared/Fermix/voice.m4a", isDirectory: false)
    static let song = URL(fileURLWithPath: "/Users/Shared/Fermix/song.mp3", isDirectory: false)
    static let film = URL(fileURLWithPath: "/Users/Shared/Fermix/clip.mp4", isDirectory: false)
    static let tab = AppPlayerPlace.pane(UUID())

    /// The player, its engine and the two facts it follows.
    @MainActor
    struct Rig {
        let engine = FakePlaybackEngine()
        let facts = FakeMediaFacts()
        let grants = FakeMediaGrants()
        let signals = AppPlayerSignals()
        let player: AppPlayer

        init() {
            player = AppPlayer(engine: engine, facts: facts, grants: grants)
            player.follow(calls: signals.calls, chatShown: signals.chat)
        }

        /// The `AVPlayer` reports that it plays, or that it stopped.
        func reportPlaying(_ playing: Bool) {
            engine.events?.playbackPlayingChanged(playing)
        }
    }

    @Test("nothing is asked of the player until something is played")
    func nothingUntilPlayed() {
        let rig = Rig()

        #expect(rig.engine.requests.isEmpty)
        #expect(rig.player.item == nil)
        #expect(!rig.player.isPlaying)
    }

    /// AVKit's own controls drive the player too, so what it was asked is
    /// not what it is doing.
    @Test("playing holds the sound and plays it, and whether it plays is the player's own word")
    func playingIsThePlayersWord() {
        let rig = Rig()

        rig.player.play(Self.voice, from: .chat)

        #expect(rig.engine.requests == ["hold voice.m4a", "play"])
        #expect(rig.player.item == AppPlayerItem(url: Self.voice, place: .chat))
        #expect(!rig.player.isPlaying, "playing was taken from the request")

        rig.reportPlaying(true)
        #expect(rig.player.isPlaying)

        rig.reportPlaying(false)
        #expect(!rig.player.isPlaying)
    }

    @Test("playing what it holds goes on from where it is, and pause pauses")
    func resumeAndPause() {
        let rig = Rig()
        rig.player.play(Self.voice, from: .chat)

        rig.player.pause()
        rig.player.play(Self.voice, from: .chat)

        #expect(rig.engine.requests == ["hold voice.m4a", "play", "pause", "play"])
    }

    @Test("one thing at a time: a film in the pane stops a sound in the chat, and a sound stops the film")
    func oneThingAtATime() {
        let rig = Rig()
        rig.player.play(Self.voice, from: .chat)
        rig.reportPlaying(true)

        rig.player.play(Self.film, from: Self.tab)
        #expect(rig.player.item == AppPlayerItem(url: Self.film, place: Self.tab))

        rig.player.play(Self.song, from: .chat)
        #expect(rig.player.item == AppPlayerItem(url: Self.song, place: .chat))
        #expect(rig.engine.requests == ["hold voice.m4a", "play", "hold clip.mp4", "play", "hold song.mp3", "play"])
    }

    /// The same file in the chat and in a tab are two items, each stopped
    /// by its own place.
    @Test("the same file in two places is two items")
    func sameFileTwoPlaces() {
        let rig = Rig()
        rig.player.play(Self.voice, from: .chat)

        rig.player.play(Self.voice, from: Self.tab)

        #expect(rig.engine.requests == ["hold voice.m4a", "play", "hold voice.m4a", "play"])
        #expect(!rig.player.holds(Self.voice, .chat))
        #expect(rig.player.holds(Self.voice, Self.tab))
    }

    @Test("a tab's cue holds its film paused where nothing plays, and never over what plays")
    func cue() {
        let rig = Rig()

        rig.player.cue(Self.film, for: Self.tab)
        #expect(rig.engine.requests == ["hold clip.mp4"])

        rig.player.play(Self.voice, from: .chat)
        rig.reportPlaying(true)
        rig.player.cue(Self.film, for: Self.tab)
        #expect(rig.player.item?.url == Self.voice, "a cue stopped a playing sound")

        rig.reportPlaying(false)
        rig.player.cue(Self.film, for: Self.tab)
        #expect(rig.player.item?.url == Self.film)
        #expect(rig.engine.requests == ["hold clip.mp4", "hold voice.m4a", "play", "hold clip.mp4"], "a cue played, or held over a playing sound")
    }

    @Test("at its end it goes back to its start, paused, and keeps what it holds")
    func endGoesBackToTheStart() {
        let rig = Rig()
        rig.player.play(Self.voice, from: .chat)
        rig.engine.events?.playbackLengthRead(42)
        rig.engine.events?.playbackMoved(to: 41.9)

        rig.engine.events?.playbackEnded()

        #expect(rig.engine.requests.last == "seek 0.0")
        #expect(rig.player.progress.position == 0)
        #expect(rig.player.progress.length == 42)
        #expect(rig.player.item?.url == Self.voice)
    }

    @Test("a stop lets go, and a place's stop lets go only of its own")
    func stops() {
        let rig = Rig()
        rig.player.play(Self.voice, from: .chat)

        rig.player.stop(Self.tab)
        #expect(rig.player.item?.url == Self.voice)

        rig.player.stop(.chat)
        #expect(rig.player.item == nil)
        #expect(rig.engine.requests.last == "hold nothing")

        rig.player.stop()
        #expect(rig.engine.requests.filter { $0 == "hold nothing" }.count == 1, "a stop with nothing held asked the player")
    }

    /// The window closing is the composition's, through this stop.
    @Test("the main window's close stops a film in the pane as a sound in the chat")
    func windowCloseStopsEverything() {
        let rig = Rig()
        rig.player.play(Self.film, from: Self.tab)

        rig.player.stop()

        #expect(rig.player.item == nil)
        #expect(rig.player.progress.position == 0)
        #expect(rig.player.progress.length == nil)
    }

    @Test("a call coming up stops the player, and nothing plays, cues or seeks until it is over")
    func callStopsThePlayer() {
        let rig = Rig()
        rig.player.play(Self.film, from: Self.tab)
        rig.reportPlaying(true)

        rig.signals.callUp(true)

        #expect(rig.player.callIsUp)
        #expect(rig.player.item == nil)
        let stopped = rig.engine.requests

        rig.player.play(Self.voice, from: .chat)
        rig.player.cue(Self.film, for: Self.tab)
        rig.player.seek(Self.voice, from: .chat, to: 10)
        #expect(rig.engine.requests == stopped, "the player was asked something during a call")

        rig.signals.callUp(false)
        rig.player.play(Self.voice, from: .chat)
        #expect(rig.player.item?.url == Self.voice)
        #expect(!rig.player.callIsUp)
    }

    /// AVKit's own controls reach the player without asking it.
    @Test("anything that starts playing during a call is paused at once")
    func playingDuringACallIsPaused() {
        let rig = Rig()
        rig.signals.callUp(true)

        rig.reportPlaying(true)

        #expect(rig.engine.requests == ["pause"])
        #expect(!rig.player.isPlaying)
    }

    @Test("the window leaving Chat stops a sound in the chat, and not a film in the pane")
    func leavingChat() {
        let rig = Rig()
        rig.player.play(Self.film, from: Self.tab)

        rig.signals.chatShown(false)
        #expect(rig.player.item?.url == Self.film)

        rig.signals.chatShown(true)
        rig.player.play(Self.voice, from: .chat)
        rig.signals.chatShown(false)
        #expect(rig.player.item == nil)
    }

    @Test("seeking a sound it does not hold holds it there, paused")
    func seekingHolds() {
        let rig = Rig()
        rig.player.play(Self.film, from: Self.tab)

        rig.player.seek(Self.voice, from: .chat, to: 12)

        #expect(rig.engine.requests == ["hold clip.mp4", "play", "hold voice.m4a", "seek 12.0"])
        #expect(rig.player.item == AppPlayerItem(url: Self.voice, place: .chat))
        #expect(rig.player.progress.position == 12)

        rig.player.seek(Self.voice, from: .chat, to: 17)
        #expect(rig.engine.requests.suffix(1) == ["seek 17.0"])
    }

    @Test("where it is and how long it is follow the player")
    func progressFollowsThePlayer() {
        let rig = Rig()
        rig.player.play(Self.voice, from: .chat)

        rig.engine.events?.playbackLengthRead(60)
        rig.engine.events?.playbackMoved(to: 12.5)

        #expect(rig.player.progress.length == 60)
        #expect(rig.player.progress.position == 12.5)

        rig.player.play(Self.song, from: .chat)
        #expect(rig.player.progress.length == nil, "a new sound kept the last one's length")
        #expect(rig.player.progress.position == 0)
    }

    /// The pane's media tabs and the chat's sounds ask the facts the player
    /// was given, the one owner of what AVFoundation says of a file.
    @Test("the player carries the one owner of what AVFoundation says of a file")
    func playerCarriesTheFacts() {
        let rig = Rig()

        #expect((rig.player.facts as? FakeMediaFacts) === rig.facts)
    }

    @Test("a step is five seconds, and a tick a quarter of one")
    func stepAndTick() {
        #expect(AppPlayer.step == 5)
        #expect(AppPlayer.tick == 0.25)
    }

    /// An item that can no longer play, its file gone from under it, is let
    /// go, so the next press holds it again.
    @Test("an item that can no longer play is let go, and the next press holds it again")
    func failureLetsGo() {
        let rig = Rig()
        rig.player.play(Self.voice, from: .chat)

        rig.engine.events?.playbackFailed()

        #expect(rig.player.item == nil)
        rig.player.play(Self.voice, from: .chat)
        #expect(rig.engine.requests == ["hold voice.m4a", "play", "hold nothing", "hold voice.m4a", "play"])
    }

    // MARK: - A voice note, by its ref (M66 §3.4, decision 1)

    static let note = FakeMediaGrants.ref("a")
    static let other = FakeMediaGrants.ref("b")

    /// A rig whose engine grants the note, and the other note, as Ogg files.
    private static func noteRig() -> Rig {
        let rig = Rig()
        rig.grants.answers[note] = FakeMediaGrants.granted(note, "ogg")
        rig.grants.answers[other] = FakeMediaGrants.granted(other, "ogg")
        return rig
    }

    @Test("pressing play holds the note's grant, holds the granted file and plays it")
    func playingANoteHoldsItsGrant() async {
        let rig = Self.noteRig()

        let outcome = await rig.player.play(ref: Self.note, from: .chat)

        #expect(outcome == FakeMediaGrants.granted(Self.note, "ogg"))
        #expect(rig.engine.requests == ["hold \(Self.note).ogg", "play"])
        #expect(rig.player.holds(ref: Self.note, .chat))
        #expect(!rig.player.holds(ref: Self.note, Self.tab))
        #expect(rig.grants.counts == [Self.note: 1])
    }

    @Test("pressing play on the note it holds plays on from where it is, with no new grant")
    func resumingANote() async {
        let rig = Self.noteRig()
        _ = await rig.player.play(ref: Self.note, from: .chat)
        rig.player.pause()

        #expect(await rig.player.play(ref: Self.note, from: .chat) == nil)
        #expect(rig.engine.requests.suffix(2) == ["pause", "play"])
        #expect(rig.grants.holds == 1)
    }

    /// The player lets the note go at each of its ends, and its grant with
    /// it, once.
    @Test("the grant is let go when the player lets the note go", arguments: ["another item", "stop", "leaving chat", "a call", "a failure"])
    func noteLetGo(_ end: String) async {
        let rig = Self.noteRig()
        _ = await rig.player.play(ref: Self.note, from: .chat)

        switch end {
        case "another item": rig.player.play(Self.song, from: .chat)
        case "stop": rig.player.stop()
        case "leaving chat": rig.signals.chatShown(false)
        case "a call": rig.signals.callUp(true)
        default: rig.engine.events?.playbackFailed()
        }

        #expect(rig.grants.log == ["hold " + Self.note, "release " + Self.note], "\(end)")
        #expect(rig.grants.held == 0)
        #expect(!rig.player.holds(ref: Self.note, .chat))
    }

    @Test("a note played in place of another lets the first one's grant go")
    func noteInPlaceOfAnother() async {
        let rig = Self.noteRig()
        _ = await rig.player.play(ref: Self.note, from: .chat)

        _ = await rig.player.play(ref: Self.other, from: .chat)

        #expect(rig.grants.counts == [Self.other: 1])
        #expect(rig.player.holds(ref: Self.other, .chat))
    }

    /// The engine restarted under a playing note: the player let it go, and
    /// the next press plays it from a fresh grant.
    @Test("a note whose file went away plays again from a fresh grant when play is pressed")
    func noteAfterItsFileWentAway() async {
        let rig = Self.noteRig()
        _ = await rig.player.play(ref: Self.note, from: .chat)
        rig.reportPlaying(true)
        rig.engine.events?.playbackFailed()
        rig.grants.answers[Self.note] = FakeMediaGrants.granted(Self.note, "ogg", in: URL(fileURLWithPath: "/fermix/again", isDirectory: true))

        _ = await rig.player.play(ref: Self.note, from: .chat)

        #expect(rig.player.item?.url == URL(fileURLWithPath: "/fermix/again/\(Self.note).ogg"))
        #expect(rig.grants.holds == 2)
        #expect(rig.grants.counts == [Self.note: 1])
    }

    @Test("a note whose bytes are gone says so, and nothing is held or played")
    func missingNote() async {
        let rig = Rig()
        rig.grants.answers[Self.note] = .missing

        #expect(await rig.player.play(ref: Self.note, from: .chat) == .missing)
        #expect(rig.engine.requests.isEmpty)
        #expect(rig.player.item == nil)
        #expect(rig.grants.held == 0)
    }

    /// A second press before the grant came: one note held, one grant kept.
    @Test("two presses while the grant is asked for hold the note once")
    func twoPresses() async throws {
        let rig = Rig()
        let first = Task { await rig.player.play(ref: Self.note, from: .chat) }
        let second = Task { await rig.player.play(ref: Self.note, from: .chat) }
        try await Self.waitUntil { rig.grants.waitingCount == 2 }

        rig.grants.answer(Self.note, FakeMediaGrants.granted(Self.note, "ogg"))
        _ = await (first.value, second.value)

        #expect(rig.engine.requests == ["hold \(Self.note).ogg", "play"])
        #expect(rig.grants.counts == [Self.note: 1])
    }

    /// The person moved on while the grant was asked for: the press plays
    /// nothing and keeps nothing.
    @Test("a press overtaken while its grant is asked for plays nothing and keeps nothing", arguments: ["a sound", "leaving chat", "a call"])
    func overtakenPress(_ overtaker: String) async throws {
        let rig = Rig()
        let press = Task { await rig.player.play(ref: Self.note, from: .chat) }
        try await Self.waitUntil { rig.grants.waitingCount == 1 }

        switch overtaker {
        case "a sound": rig.player.play(Self.song, from: .chat)
        case "leaving chat": rig.signals.chatShown(false)
        default: rig.signals.callUp(true)
        }
        rig.grants.answer(Self.note, FakeMediaGrants.granted(Self.note, "ogg"))
        _ = await press.value

        #expect(!rig.player.holds(ref: Self.note, .chat), "\(overtaker)")
        #expect(rig.grants.held == 0)
        #expect(!rig.engine.requests.contains("hold \(Self.note).ogg"))
    }

    @Test("a note moves along only while the player holds it")
    func seekingANote() async {
        let rig = Self.noteRig()

        rig.player.seek(ref: Self.note, from: .chat, to: 10)
        #expect(rig.engine.requests.isEmpty)
        #expect(rig.grants.holds == 0)

        _ = await rig.player.play(ref: Self.note, from: .chat)
        rig.player.seek(ref: Self.note, from: .chat, to: 10)
        #expect(rig.engine.requests.last == "seek 10.0")
        #expect(rig.player.progress.position == 10)
        #expect(rig.grants.counts == [Self.note: 1], "a seek let the grant go")
    }

    @Test("nothing is asked for while a call is up")
    func noteDuringACall() async {
        let rig = Self.noteRig()
        rig.signals.callUp(true)

        #expect(await rig.player.play(ref: Self.note, from: .chat) == nil)
        #expect(rig.grants.holds == 0)
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }

        try #require(condition(), "the player did not reach the expected point")
    }
}

/// What AVFoundation says of a sound or a film before anything plays it
/// (M66 §3.4): asked of the file itself, never of its name, and a length only
/// where it is a real one.
@Suite("Media facts")
struct MediaFactsTests {
    @Test("a length is a real, positive time, and nothing else")
    func lengthIsRealAndPositive() {
        #expect(AVFoundationMediaFacts.seconds(CMTime(seconds: 61.5, preferredTimescale: 600)) == 61.5)
        #expect(AVFoundationMediaFacts.seconds(nil) == nil)
        #expect(AVFoundationMediaFacts.seconds(.zero) == nil)
        #expect(AVFoundationMediaFacts.seconds(CMTime(seconds: -2, preferredTimescale: 600)) == nil)
        #expect(AVFoundationMediaFacts.seconds(.invalid) == nil)
        #expect(AVFoundationMediaFacts.seconds(.indefinite) == nil)
        #expect(AVFoundationMediaFacts.seconds(.positiveInfinity) == nil)
    }

    /// What cannot play is opened outside, whatever its name says.
    @Test("a file named like a film that is not one cannot play, and has no length")
    func nameIsNotPlayability() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let broken = folder.url.appendingPathComponent("broken.mp4", isDirectory: false)
        try Data("hello".utf8).write(to: broken)

        #expect(await !AVFoundationMediaFacts().isPlayable(broken))
        #expect(await AVFoundationMediaFacts().length(of: broken) == nil)
    }
}
