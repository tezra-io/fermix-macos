import Foundation
import Testing

@testable import FermixAppCore

/// What a sound's player in the chat shows (M66 §3.4, §7): its length while
/// it is still and its place while it is under way, the track's fill, and
/// where a click, a drag, an arrow key or VoiceOver's increment lands.
@Suite("Chat sound row")
struct ChatSoundRowTests {
    @Test("a sound the player does not hold shows its length and an empty track")
    func stillShowsItsLength() {
        let state = ChatSoundState(held: false, playing: false, position: 0, length: 84)

        #expect(!state.underWay)
        #expect(state.shownTime == 84)
        #expect(state.filled == 0)
    }

    @Test("a sound playing shows where it is and fills the track that far")
    func playingShowsItsPlace() {
        let state = ChatSoundState(held: true, playing: true, position: 21, length: 84)

        #expect(state.underWay)
        #expect(state.shownTime == 21)
        #expect(state.filled == 0.25)
    }

    @Test("a sound paused past its start is still under way, and shows where it is")
    func pausedShowsItsPlace() {
        let state = ChatSoundState(held: true, playing: false, position: 30, length: 60)

        #expect(state.underWay)
        #expect(state.shownTime == 30)
        #expect(state.filled == 0.5)
    }

    /// The player takes an ended sound back to its start, paused.
    @Test("a sound back at its start after its end shows its length again")
    func endedShowsItsLength() {
        let state = ChatSoundState(held: true, playing: false, position: 0, length: 60)

        #expect(!state.underWay)
        #expect(state.shownTime == 60)
        #expect(state.filled == 0)
    }

    @Test("a sound whose length is not read yet shows no time and fills nothing")
    func unknownLength() {
        let state = ChatSoundState(held: false, playing: false, position: 0, length: nil)

        #expect(state.shownTime == nil)
        #expect(state.filled == 0)
        #expect(state.at(0.5) == nil)
    }

    @Test("an arrow key or VoiceOver's increment moves five seconds, held to the sound")
    func stepsAreFiveSeconds() {
        let middle = ChatSoundState(held: true, playing: true, position: 30, length: 60)
        let start = ChatSoundState(held: true, playing: false, position: 3, length: 60)
        let end = ChatSoundState(held: true, playing: true, position: 58, length: 60)
        let unread = ChatSoundState(held: false, playing: false, position: 0, length: nil)

        #expect(middle.stepped(forward: true) == 35)
        #expect(middle.stepped(forward: false) == 25)
        #expect(start.stepped(forward: false) == 0)
        #expect(end.stepped(forward: true) == 60)
        #expect(unread.stepped(forward: true) == 5)
        #expect(unread.stepped(forward: false) == 0)
    }

    @Test("a click or a drag lands where it is along the track, and never past either end")
    func clickLandsAlongTheTrack() {
        let state = ChatSoundState(held: false, playing: false, position: 0, length: 80)

        #expect(state.at(0.25) == 20)
        #expect(state.at(-0.5) == 0)
        #expect(state.at(1.5) == 80)
    }

    @Test("the fill never runs past the track")
    func fillIsHeld() {
        #expect(ChatSoundState(held: true, playing: true, position: 90, length: 60).filled == 1)
        #expect(ChatSoundState(held: true, playing: true, position: 10, length: 0).filled == 0)
    }

    @Test("the time is written with the hours only where it has any")
    func writtenTime() {
        #expect(ChatSoundState.written(0) == "0:00")
        #expect(ChatSoundState.written(65) == "1:05")
        #expect(ChatSoundState.written(3725) == "1:02:05")
    }

    /// The row is placed by the chat, over the app's one player.
    @MainActor
    @Test("a row is made from the file, its name and the one player, and reads nothing until it is drawn")
    func rowIsMadeOverThePlayer() {
        let engine = FakePlaybackEngine()
        let player = AppPlayer(engine: engine, facts: FakeMediaFacts())

        _ = ChatSoundRow(url: URL(fileURLWithPath: "/Users/Shared/Fermix/voice.m4a"), name: "voice.m4a", player: player)

        #expect(engine.requests.isEmpty)
    }

    @Test("VoiceOver hears the time in words")
    func spokenTime() {
        #expect(ChatSoundState.spoken(65) == Duration.seconds(65).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))
        #expect(!ChatSoundState.spoken(65).contains(":"))
    }
}
