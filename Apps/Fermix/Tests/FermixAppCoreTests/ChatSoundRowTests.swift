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
        let player = AppPlayer(engine: engine, facts: FakeMediaFacts(), grants: FakeMediaGrants())

        _ = ChatSoundRow(url: URL(fileURLWithPath: "/Users/Shared/Fermix/voice.m4a"), name: "voice.m4a", player: player)

        #expect(engine.requests.isEmpty)
    }

    /// A voice note is placed by its row, over the one player and the
    /// chat's previews: nothing is granted, read or played until it is drawn
    /// on screen.
    @MainActor
    @Test("a voice note is made from its ref and the one player, and asks for nothing until it is drawn")
    func voiceNoteIsMadeOverThePlayer() {
        let engine = FakePlaybackEngine()
        let grants = FakeMediaGrants()
        let player = AppPlayer(engine: engine, facts: FakeMediaFacts(), grants: grants)

        _ = ChatVoiceNote(note: CompanionMediaRows.voice, transcript: AttributedString("Hello"), speaker: "user", player: player)

        #expect(engine.requests.isEmpty)
        #expect(grants.log.isEmpty)
    }

    /// AVFoundation misreads the length of an Ogg Opus voice note: a 6.69 s
    /// note loads as 9.36 s, measured. Its levels count the frames really
    /// decoded, so once they are read their length is the one the row goes by.
    @Test("a row's length is its decoded one once its levels are read, AVFoundation's until then")
    func lengthPrecedence() {
        let decoded = SoundLevels(values: [0.5], seconds: 6.69)

        #expect(ChatSoundState.length(levels: decoded, player: 9.36, file: 9.36) == 6.69)
        #expect(ChatSoundState.length(levels: decoded, player: nil, file: nil) == 6.69)
        #expect(ChatSoundState.length(levels: nil, player: 9.36, file: 9) == 9.36)
        #expect(ChatSoundState.length(levels: nil, player: nil, file: 9) == 9)
        #expect(ChatSoundState.length(levels: nil, player: nil, file: nil) == nil)
    }

    @Test("a note whose levels say 6.69 s and whose player says 9.36 s shows 0:07 still, fills fully at 6.69 s, and seeks by 6.69 s")
    func decodedLengthRules() {
        let decoded = SoundLevels(values: [0.5], seconds: 6.69)
        let still = ChatSoundState(held: false, playing: false, position: 0, length: ChatSoundState.length(levels: decoded, player: nil, file: nil))
        let ending = ChatSoundState(held: true, playing: true, position: 6.69, length: ChatSoundState.length(levels: decoded, player: 9.36, file: nil))
        let late = ChatSoundState(held: true, playing: true, position: 4, length: ChatSoundState.length(levels: decoded, player: 9.36, file: nil))

        #expect(still.shownTime.map(ChatSoundState.written) == "0:07")
        #expect(still.shownTime.map(ChatSoundState.spoken) == ChatSoundState.spoken(7))
        #expect(ending.filled == 1)
        #expect(ChatWaveformLayout.played(ending.filled, bars: 60) == 60)
        #expect(ending.at(0.5) == 3.345)
        #expect(ending.at(1) == 6.69)
        #expect(late.stepped(forward: true) == 6.69)
    }

    @Test("before its levels are read, a note goes by the player's length")
    func playerLengthBeforeLevels() {
        let unread = ChatSoundState(held: false, playing: false, position: 0, length: ChatSoundState.length(levels: nil, player: nil, file: nil))
        let ending = ChatSoundState(held: true, playing: true, position: 6.69, length: ChatSoundState.length(levels: nil, player: 9.36, file: nil))
        let late = ChatSoundState(held: true, playing: true, position: 4, length: ChatSoundState.length(levels: nil, player: 9.36, file: nil))

        #expect(unread.shownTime == nil)
        #expect(ending.filled == 6.69 / 9.36)
        #expect(ending.at(1) == 9.36)
        #expect(late.stepped(forward: true) == 9)
    }

    @Test("VoiceOver hears the time in words")
    func spokenTime() {
        #expect(ChatSoundState.spoken(65) == Duration.seconds(65).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))
        #expect(!ChatSoundState.spoken(65).contains(":"))
    }
}

/// A sound's waveform (M66 §3.4): bars two points wide two apart across the
/// width it has, filled bar by bar as far as the sound has played, resting
/// low and even until its levels are read, and never under a short line.
@Suite("Chat waveform")
struct ChatWaveformTests {
    @Test("the bars are thin and close, and the waveform as tall as a line of text with its button")
    func metrics() {
        #expect(ChatMetrics.soundBarWidth == 2)
        #expect(ChatMetrics.soundBarGap == 2)
        #expect(ChatWaveformLayout.pitch == 4)
        #expect(ChatMetrics.soundWaveHeight == 22)
        #expect(ChatMetrics.soundWaveHeight < ChatMetrics.soundButton)
    }

    @Test("as many bars fit as there is width for, the last with no gap after it")
    func barsFit() {
        #expect(ChatWaveformLayout.bars(fitting: 0) == 0)
        #expect(ChatWaveformLayout.bars(fitting: 1) == 0)
        #expect(ChatWaveformLayout.bars(fitting: 2) == 1)
        #expect(ChatWaveformLayout.bars(fitting: 5) == 1)
        #expect(ChatWaveformLayout.bars(fitting: 6) == 2)
        #expect(ChatWaveformLayout.bars(fitting: 238) == 60)
        #expect(ChatWaveformLayout.bars(fitting: -4) == 0)

        for width in stride(from: 0.0, through: 320, by: 0.5) {
            let count = ChatWaveformLayout.bars(fitting: width)
            #expect(Double(count) * ChatWaveformLayout.pitch - ChatMetrics.soundBarGap <= width)
        }
    }

    /// No waveform is wider than its player, so none has more bars than a
    /// sound is read in, and drawing only ever merges its stretches.
    @Test("the widest waveform has no more bars than a sound has stretches")
    func widestFitsTheStretches() {
        #expect(ChatWaveformLayout.bars(fitting: ChatMetrics.soundMaxWidth) <= SoundLevels.buckets)
    }

    @Test("the bars fill as far as the sound has played, bar by bar, never past either end")
    func playedBars() {
        #expect(ChatWaveformLayout.played(0, bars: 60) == 0)
        #expect(ChatWaveformLayout.played(0.5, bars: 60) == 30)
        #expect(ChatWaveformLayout.played(1, bars: 60) == 60)
        #expect(ChatWaveformLayout.played(1.5, bars: 60) == 60)
        #expect(ChatWaveformLayout.played(-1, bars: 60) == 0)
        #expect(ChatWaveformLayout.played(0.01, bars: 60) == 1)
        #expect(ChatWaveformLayout.played(0.005, bars: 60) == 0)
        #expect(ChatWaveformLayout.played(0.5, bars: 0) == 0)

        let quarter = ChatSoundState(held: true, playing: true, position: 21, length: 84)
        #expect(ChatWaveformLayout.played(quarter.filled, bars: 48) == 12)
        let still = ChatSoundState(held: false, playing: false, position: 0, length: 84)
        #expect(ChatWaveformLayout.played(still.filled, bars: 48) == 0)
    }

    /// Before the levels are read the same bars rest low and even, so
    /// nothing moves when they come: the same count at the same width.
    @Test("before its levels are read the waveform rests low and even, with as many bars as after")
    func restingBars() {
        let resting = ChatWaveformLayout.levels(nil, bars: 12)
        let heard = ChatWaveformLayout.levels(SoundLevels(values: (0..<64).map { Float($0) / 63 }, seconds: 8), bars: 12)

        #expect(resting == Array(repeating: ChatMetrics.soundRestingLevel, count: 12))
        #expect(heard.count == resting.count)
        #expect(heard.last == 1)
        #expect(ChatMetrics.soundRestingLevel > 0)
        #expect(ChatMetrics.soundRestingLevel < 0.25)
    }

    @Test("a bar is never under the shortest, so silence is still a line, and never over the waveform")
    func barHeights() {
        let height = ChatMetrics.soundWaveHeight

        #expect(ChatWaveformLayout.height(of: 0, in: height) == ChatMetrics.soundBarMinimum)
        #expect(ChatWaveformLayout.height(of: 1, in: height) == height)
        #expect(ChatWaveformLayout.height(of: 0.5, in: height) == ChatMetrics.soundBarMinimum + (height - ChatMetrics.soundBarMinimum) / 2)
        #expect(ChatWaveformLayout.height(of: 2, in: height) == height)
        #expect(ChatWaveformLayout.height(of: -1, in: height) == ChatMetrics.soundBarMinimum)
        #expect(ChatMetrics.soundBarMinimum > ChatMetrics.soundBarWidth)
    }
}
