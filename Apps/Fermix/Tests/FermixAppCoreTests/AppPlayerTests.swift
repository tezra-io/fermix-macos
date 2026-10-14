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
        let signals = AppPlayerSignals()
        let player: AppPlayer

        init() {
            player = AppPlayer(engine: engine)
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

    /// What cannot play is opened outside, whatever its name says.
    @Test("whether a file can play is AVFoundation's word about the file, never its name")
    func playabilityIsTheFilesOwn() async {
        let rig = Rig()
        let broken = URL(fileURLWithPath: "/Users/Shared/Fermix/broken.mp4", isDirectory: false)
        let oddlyNamed = URL(fileURLWithPath: "/Users/Shared/Fermix/recording.data", isDirectory: false)
        rig.engine.playable = [Self.film, oddlyNamed]
        rig.engine.lengths = [Self.voice: 61]

        #expect(await rig.player.isPlayable(Self.film))
        #expect(await rig.player.isPlayable(oddlyNamed))
        #expect(await !rig.player.isPlayable(broken))
        #expect(await rig.player.length(of: Self.voice) == 61)
        #expect(await rig.player.length(of: Self.song) == nil)
    }

    @Test("a step is five seconds, and a tick a quarter of one")
    func stepAndTick() {
        #expect(AppPlayer.step == 5)
        #expect(AppPlayer.tick == 0.25)
    }
}
