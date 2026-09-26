import DJCDomain
import Foundation

/// 파형·분석 캐시는 곡당 약 0.6MB다(전곡이면 4GB대). 합계가 상한을 넘으면 오래 안 쓴 파일부터 지운다.
public enum CacheMaintenance {
    public static func prune(maxBytes: Int = 1_500_000_000) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        var files: [(url: URL, size: Int, used: Date)] = []
        for directory in [WaveformCache.directory, PartAnalyzer.cacheDirectory] {
            for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [] {
                let values = try? url.resourceValues(forKeys: Set(keys))
                files.append((url, values?.fileSize ?? 0,
                              values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast))
            }
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        for file in files.sorted(by: { $0.used < $1.used }) {
            try? fm.removeItem(at: file.url)
            total -= file.size
            if total <= maxBytes * 8 / 10 { break }
        }
    }
}
