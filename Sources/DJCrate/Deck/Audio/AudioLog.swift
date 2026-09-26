import AVFoundation
import Foundation

/// `DJC_AUDIO_DEBUG=1`이면 재생 경로를 표준 오류에 기록한다.
enum AudioDebug {
    static let enabled = ProcessInfo.processInfo.environment["DJC_AUDIO_DEBUG"] != nil
    nonisolated static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        FileHandle.standardError.write(Data("[audio \(String(format: "%.3f", now))] \(message())\n".utf8))
    }
}

/// 상시 오디오 사건 기록(`~/Library/Logs/DJCrate/audio.log`). 재생·정지·구성 변경·복구만 짧게 남긴다.
/// "소리가 안 나온다"가 다시 생기면 이 파일로 무슨 일이 있었는지 본다. 1MB를 넘으면 새로 시작한다.
enum AudioEvents {
    private static let queue = DispatchQueue(label: "djc.audio-events", qos: .utility)
    private static let url = URL.libraryDirectory.appending(path: "Logs/DJCrate/audio.log")
    static func record(_ message: String) {
        AudioDebug.log(message)
        let line = "\(Date.now.formatted(.iso8601)) \(message)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
                try? manager.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
