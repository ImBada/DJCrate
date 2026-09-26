import DJCDomain
import Foundation

/// 앱 문구는 우리가 정한 이유·할 일만 보여 주고, 진단 원문은 표준 오류에 남긴다.
enum AppErrorMessage {
    static func message(for error: any Error) -> String {
        log(error)
        guard let error = error as? DJCError else {
            return "디스크 공간과 권한을 확인한 뒤 다시 시도하세요."
        }
        let description = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
        return [description, error.recoverySuggestion].compactMap { $0 }.joined(separator: ": ")
    }

    static func log(_ error: any Error) {
        FileHandle.standardError.write(Data("[앱 오류] \(error)\n".utf8))
    }
}
