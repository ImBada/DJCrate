import DJCDomain
import Foundation

/// Flip 기록(Serato Flip처럼): 재생하며 쓴 점프·루프만 모아 같은 소리로 재생되는 편집본을 만든다.
/// rekordbox에는 Flip 재생이 없어 결과는 새 곡 파일(추가한 곡)이다. 기록 규칙은 `FlipRecording`, 결과 창은 `FlipWindow`.
///
/// 들린 구간은 오디오가 재생 한 번이 끝날 때마다 샘플 단위로 알린다(`DeckAudioEngine.onPlayedRun`, 루프는 바퀴마다).
extension DeckModel {
    /// Flip 기록을 시작할 수 없는 이유와 할 일(기록 중이면 nil: 마치기는 언제든 된다)
    var flipUnavailableReason: String? {
        guard !isFlipRecording else { return nil }
        if isWriteLocked { return String(ui: "rekordbox 쓰기가 끝난 뒤 Flip을 기록하세요") }
        if row == nil || draft == nil { return String(ui: "곡을 덱에 불러오고 초안 읽기가 끝난 뒤 Flip을 기록하세요") }
        return playbackUnavailableReason
    }

    /// 기록을 시작한다. 이미 재생 중이면 지금부터 센다(그 전에 쓴 점프·루프는 넣지 않는다).
    func startFlipRecording() {
        guard !isFlipRecording else { return }
        if let reason = flipUnavailableReason {
            showToast(reason)
            return
        }
        flipRecording = FlipRecording()
        // 기록하는 동안만 들린 구간을 받는다(기록하지 않을 때 멈춤·점프마다 구간을 계산하지 않게).
        audio.onPlayedRun = { [weak self] run in self?.flipRecording?.record(run) }
        _ = audio.takePlayedRun()
        isFlipRecording = true
        showToast(String(ui: "Flip 기록 중: 재생하며 핫큐·루프를 쓴 뒤 Flip을 다시 누르면 편집본으로 만듭니다"), kind: .success)
    }

    /// 기록을 마치고 기록을 돌려준다. 재생은 그대로 둔다(지금까지 들린 곳까지 넣는다).
    func finishFlipRecording() -> FlipRecording? {
        guard isFlipRecording, var recording = flipRecording else { return nil }
        if let run = audio.takePlayedRun() { recording.record(run) }
        audio.onPlayedRun = nil
        flipRecording = nil
        isFlipRecording = false
        return recording
    }

    /// 기록을 버린다(곡을 바꿀 때).
    func cancelFlipRecording() {
        audio.onPlayedRun = nil
        flipRecording = nil
        isFlipRecording = false
    }

    /// 곡을 바꿔 기록을 버리기 전에 묻는다. 기록 중이 아니거나 점프·루프가 아직 없으면 묻지 않는다.
    /// - Returns: 버려도 되면 true(기록은 곡을 바꿀 때 `load`가 지운다). 취소하면 false이고 기록은 이어 간다.
    func confirmDiscardingFlip() -> Bool {
        guard isFlipRecording else { return true }
        // 지금 재생 안에서 아직 알리지 않은 점프도 센다.
        if let run = audio.takePlayedRun() { flipRecording?.record(run) }
        guard let recording = flipRecording, !recording.isEmpty else { return true }
        return prompter.show(ReflectionPrompt(
            title: String(ui: "Flip 기록을 버릴까요?"),
            text: String(ui: "곡을 바꾸면 지금까지 기록한 점프·루프 \(recording.jumpCount)개를 버립니다. 버린 기록은 다시 만들 수 없으니, 남기려면 취소하고 Flip을 눌러 기록을 마치세요"),
            confirm: String(ui: "기록 버리기"), destructive: true))
    }
}
