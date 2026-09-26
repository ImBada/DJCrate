import DJCAnalysis
import DJCDomain
import DJCStorage
import AppKit
import Foundation
import RekordboxKit

/// 재생·탐색·끌기·CUE(CDJ 방식)
extension DeckModel {
    // MARK: - 재생

    func togglePlay() {
        guard canPlay else { return }
        AudioEvents.record("조작 재생/정지 · 재생 중=\(isPlaying) · 미리듣기=\(isCuePreviewing) · 위치 \(String(format: "%.2f", playhead))")
        if isCuePreviewing {
            if isCueHeld {
                // CUE를 누른 채 재생을 누르면 손을 떼도 계속 재생한다(CDJ와 같다).
                isCuePreviewing = false
                return
            }
            // CUE를 뗀 신호를 놓쳐 미리 듣기 상태만 남은 경우: 평소처럼 재생/정지한다.
            AudioEvents.record("남아 있던 미리 듣기 상태를 풀었음")
            isCuePreviewing = false
        }
        if isPlaying {
            audio.pause()
            playhead = audio.position
            isPlaying = false
            ticker.stop()
        } else {
            if playhead >= duration - 0.05 { playhead = 0 }
            startPlayback(from: playhead)
        }
    }

    func startPlayback(from time: Double) {
        if audio.play(from: time) {
            isPlaying = true
            ticker.start()
        } else {
            isPlaying = false
            ticker.stop()
            playhead = min(time, duration)
        }
    }


    func tick() {
        guard isPlaying else { return }
        PerfProbe.tick()
        let now = ProcessInfo.processInfo.systemUptime
        if now - meterStamp >= 1.0 / 30 {
            meterStamp = now
            meterFrame &+= 1
        }
        // CUE를 뗀 신호(키·마우스)를 놓치면 미리 듣기가 끝나지 않는다. 실제로 누르고 있지 않으면 뗀 것으로 본다.
        if isCuePreviewing, !isCueHeld {
            AudioEvents.record("CUE를 뗀 신호를 놓쳐 미리 듣기를 끝냄")
            cueUp()
            return
        }
        audio.recoverIfStalled()
        let previous = playhead
        playhead = audio.position
        if handleLoops(previous: previous) { return }
        updateGridBPM()
        audio.scheduleClicks(grid)
        if !audio.isPlaying || playhead >= duration - 0.01 {
            audio.stop()
            isPlaying = false
            isCuePreviewing = false
            ticker.stop()
            playhead = min(playhead, duration)
        }
    }


    /// 한 번의 이동(패드·목록 클릭 등). 재생 중이면 그 위치에서 다시 재생한다.
    func seek(_ time: Double) {
        // 루프 중에 다른 자리로 옮기면 루프에서 빠져나온다(루프 핫큐를 누른 경우는 부른 쪽이 다시 건다).
        if isLooping, abs(time - playhead) > 0.005 { exitLoop() }
        jump(to: time)
    }

    /// 목록은 재생 상태를 유지하며 시작점만 부른다. 같은 위치의 루프를 눌러도 반복은 풀린다.
    func selectCueFromList(_ id: EditableCue.ID) {
        guard let target = cue(id) else { return }
        selectedCueID = id
        if isLooping { exitLoop() }
        seek(target.time)
    }

    /// 루프 상태를 건드리지 않고 옮긴다(루프 길이를 줄여 끝 밖에 있게 됐을 때 등).
    func jump(to time: Double) {
        isCuePreviewing = false
        playhead = min(max(time, 0), duration)
        updateGridBPM()
        if isPlaying {
            startPlayback(from: playhead)
        } else {
            audio.seekWhilePaused(playhead)
        }
    }

    /// 끌기 시작: 재생 중이면 소리를 멈추고, 놓을 때 한 번만 다시 재생한다.
    func beginScrub() {
        isCuePreviewing = false
        guard isPlaying else { return }
        resumeAfterScrub = true
        audio.pause()
        isPlaying = false
        ticker.stop()
    }

    func scrub(to time: Double) {
        if isLooping, abs(time - playhead) > 0.005 { exitLoop() }
        playhead = min(max(time, 0), duration)
        audio.seekWhilePaused(playhead)
        updateGridBPM()
    }

    func endScrub() {
        guard resumeAfterScrub else { return }
        resumeAfterScrub = false
        startPlayback(from: playhead)
    }

    /// 휠·트랙패드 가로 스크롤처럼 짧은 간격으로 이어지는 이동. 150ms 멈추면 그때 재생을 이어 간다.
    func scrubCoalesced(to time: Double) {
        if isPlaying { beginScrub() }
        scrub(to: time)
        guard resumeAfterScrub else { return }
        seekRestartTask?.cancel()
        seekRestartTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self.endScrub()
        }
    }

    func stopPlayback() {
        ticker.stop()
        audio.stop()
        isPlaying = false
        isCuePreviewing = false
    }


    // MARK: - CUE (CDJ 방식)

    /// CUE를 누름.
    /// - 재생 중: 큐 지점으로 돌아가 멈춘다.
    /// - 멈춤 + 큐 지점이 아닌 곳: 그 자리를 새 큐 지점으로 정한다(퀀타이즈가 켜져 있으면 박에 맞춘다).
    /// - 멈춤 + 큐 지점: 누르고 있는 동안 재생한다. 떼면 큐 지점으로 돌아간다.
    func cueDown() {
        guard canPlay, !isCuePreviewing else { return }
        AudioEvents.record("조작 CUE 누름 · 재생 중=\(isPlaying) · 위치 \(String(format: "%.2f", playhead)) · 큐 \(String(format: "%.2f", cuePoint))")
        if isPlaying {
            returnToCue()
        } else if abs(playhead - cuePoint) > Self.cueTolerance {
            cuePoint = snapped(playhead)
            playhead = cuePoint
            audio.seekWhilePaused(cuePoint)
            updateGridBPM()
        } else {
            isCuePreviewing = true
            startPlayback(from: cuePoint)
            if !isPlaying { isCuePreviewing = false }
        }
    }

    /// CUE를 뗌: 미리 듣던 중이면 큐 지점으로 돌아가 멈춘다.
    func cueUp() {
        guard isCuePreviewing else { return }
        AudioEvents.record("조작 CUE 뗌(미리 듣기 끝)")
        isCuePreviewing = false
        if isPlaying { returnToCue() }
    }

    /// CUE를 지금 실제로 누르고 있는지(CUE 단축키 또는 마우스 왼쪽 버튼). 미리 듣기 상태가 남지 않게 확인한다.
    var isCueHeld: Bool {
        shortcuts.keys(for: .cue).contains { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
            || (NSEvent.pressedMouseButtons & 1) != 0
    }

    /// 멈춘 채 큐 지점에 있는지(CUE 버튼 불빛).
    var isAtCue: Bool { !isPlaying && abs(playhead - cuePoint) <= Self.cueTolerance }

    static let cueTolerance = 0.01

    func returnToCue() {
        exitLoop()
        audio.pause()
        ticker.stop()
        isPlaying = false
        playhead = cuePoint
        audio.seekWhilePaused(cuePoint)
        updateGridBPM()
    }

    /// Q/E: 이전·다음 큐(메모리·핫큐)로 간다. 부른 큐는 CUE 지점이 된다(CDJ의 메모리 큐 호출과 같다).
    /// 재생 중이면 거기서 계속 재생하고, 멈춰 있으면 그 자리에서 대기한다(C로 바로 미리 듣기).
    func jumpToCue(forward: Bool) {
        guard canPlay, let cues = draft?.cues, !cues.isEmpty else { return }
        let times = cues.sorted { $0.time < $1.time }
        let target: EditableCue?
        if forward {
            target = times.first { $0.time > playhead + Self.cueTolerance }
        } else {
            // 재생 중에는 방금 부른 큐에서 0.25초 안이면 그 앞 큐로 간다(아니면 지금 구간의 시작으로).
            let slack = isPlaying ? 0.25 : Self.cueTolerance
            target = times.last { $0.time < playhead - slack }
        }
        guard let target else { return }
        selectedCueID = target.id
        cuePoint = target.time
        seek(target.time)
    }

    // MARK: - 박 이동

    /// ←→·메뉴: 선택한 큐가 있으면 그 큐를 밀고, 없으면 재생 위치를 옮긴다(Shift는 1마디 = `BeatJump.beatsPerBar`박).
    func step(beats: Int) {
        guard !isWriteLocked else { return }
        if !nudgeSelectedCue(beats: beats) { beatJump(beats: beats) }
    }

    /// 재생 위치를 박 단위로 옮긴다(규칙은 `BeatJump`, VoiceOver 조절도 이 함수). 재생 중이면 박 안의 위치를 지켜 이어 재생한다.
    func beatJump(beats: Int) {
        guard !isWriteLocked, canPlay || grid != nil else { return }
        seek(BeatJump.target(from: playhead, beats: beats, grid: grid, duration: duration, keepsPhase: isPlaying))
    }

    /// 선택한 큐를 박 단위로 민다. 선택이 없으면 false(키를 다른 곳에 넘긴다).
    func nudgeSelectedCue(beats: Int) -> Bool {
        guard let id = selectedCueID, cue(id) != nil else { return false }
        nudge(id, beats: beats)
        return true
    }

    func deleteSelectedCue() -> Bool {
        guard let id = selectedCueID, cue(id) != nil else { return false }
        delete(id)
        return true
    }
}
