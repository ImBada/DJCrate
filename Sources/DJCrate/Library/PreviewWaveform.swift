import AppKit
import DJCAnalysis
import DJCDomain
import DJCStorage
import RekordboxKit

struct PreviewWaveformRequest: Hashable, Sendable {
    let url: URL?
    let revision: String
    let appearance: String
    var mode: WaveformColorMode = .threeBand
    var emphasized = false
    var audioURL: URL?
    var trackKey = ""

    var cacheKey: NSString {
        [url?.absoluteString ?? "", revision, appearance, mode.rawValue, String(emphasized), audioURL?.absoluteString ?? "", trackKey]
            .joined(separator: "\u{1F}") as NSString
    }
}

/// 색 선택과 그리기를 한곳에 모으고, 셀에는 완성된 이미지만 넘긴다.
enum PreviewWaveformRenderer {
    static func image(_ waveform: AnlzPreviewWaveform, mode: WaveformColorMode,
                      appearance: String, emphasized: Bool = false) -> CGImage? {
        let reduced = waveform.downsampled(to: 400)
        let columns = mode == .blue ? reduced.blueColumns : (reduced.colorColumns ?? reduced.blueColumns)
        // 선택 배경에서도 밴드·RGB 구분을 남기고 어두운 배경용 대비를 쓴다.
        return WaveformBitmap.image(columns, mode: mode, appearance: emphasized ? .darkAqua : NSAppearance.Name(appearance),
                                    height: 40, width: 400)
    }
}

enum PreviewWaveformSource {
    static func addingFallback(to source: AnlzPreviewWaveform?, audioURL: URL?, key: String) -> AnlzPreviewWaveform? {
        var blue = source?.blueColumns
        var bands = source?.colorColumns
        if blue == nil || bands == nil, !Task.isCancelled, let audioURL, !key.isEmpty,
           let fallback = try? WaveformCache.load(fileAt: audioURL, key: key) {
            let columns = fallback.downsampled(to: 400).colorColumns
            if blue == nil { blue = columns }
            if bands == nil { bands = columns }
        }
        guard let blue = blue ?? bands else { return nil }
        return AnlzPreviewWaveform(blue: blue, color: bands).downsampled(to: 400)
    }
}

/// 파일 읽기와 비트맵 생성은 메인 액터 밖에서 직렬 처리한다. 빈 자료도 기억한다.
actor PreviewWaveformCache {
    static let shared = PreviewWaveformCache()
    private let store: PreviewWaveformStore

    init(store: PreviewWaveformStore = .shared) { self.store = store }
    private final class Entry {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }
    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.countLimit = 512
        return cache
    }()

    func image(for request: PreviewWaveformRequest) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let key = request.trackKey.isEmpty ? request.url?.absoluteString ?? "" : request.trackKey
        let source = PreviewWaveformStore.Source(uuid: key, url: request.url)
        let revision = await store.revision(for: source)
        let imageKey = "\(request.cacheKey)\u{1F}\(revision)" as NSString
        guard !Task.isCancelled else { return nil }
        if let hit = cache.object(forKey: imageKey) { return hit.image }
        let raw = await store.waveform(for: source)
        var image: CGImage?
        if let waveform = PreviewWaveformSource.addingFallback(to: raw, audioURL: request.audioURL, key: request.trackKey),
           !Task.isCancelled {
            image = PreviewWaveformRenderer.image(waveform, mode: request.mode,
                                                 appearance: request.appearance, emphasized: request.emphasized)
        }
        guard !Task.isCancelled else { return nil }
        cache.setObject(Entry(image), forKey: imageKey, cost: image.map { $0.bytesPerRow * $0.height } ?? 1)
        return image
    }
}

/// 재사용·모양새 전환 뒤 늦게 도착한 이미지는 버린다. 재생 틱은 읽지 않는다.
final class PreviewWaveformCell: NSTableCellView {
    private let waveformLayer = CALayer()
    private var source: (url: URL?, revision: String, mode: WaveformColorMode, audioURL: URL?, key: String)?
    private var request: PreviewWaveformRequest?
    private var task: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(waveformLayer)
        setAccessibilityElement(true)
        setAccessibilityLabel("미리 보기 파형")
        setAccessibilityValue("분석 자료 없음")
        toolTip = "곡 전체의 미리 보기 파형 · 분석 자료가 없는 곡은 빈 칸"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(url: URL?, revision: String, mode: WaveformColorMode = .threeBand, audioURL: URL? = nil, key: String = "") {
        source = (url, revision, mode, audioURL, key)
        refresh()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refresh() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            task?.cancel()
            request = nil
        } else {
            refresh()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waveformLayer.frame = bounds.insetBy(dx: 3, dy: 2)
        CATransaction.commit()
    }

    private func refresh() {
        guard let source else { return }
        let appearance = effectiveAppearance.bestMatch(from: [.accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua, .aqua, .darkAqua]) ?? .aqua
        let next = PreviewWaveformRequest(url: source.url, revision: source.revision,
                                          appearance: appearance.rawValue, mode: source.mode, emphasized: backgroundStyle == .emphasized,
                                          audioURL: source.audioURL, trackKey: source.key)
        guard request != next else { return }
        request = next
        task?.cancel()
        show(nil)
        task = Task(priority: .utility) { [weak self] in
            let image = await PreviewWaveformCache.shared.image(for: next)
            guard !Task.isCancelled, let self, self.request == next else { return }
            self.show(image)
        }
    }

    private func show(_ image: CGImage?) {
        guard image != nil || waveformLayer.contents != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waveformLayer.contents = image
        CATransaction.commit()
        setAccessibilityValue(image == nil ? "분석 자료 없음" : "곡 전체 파형")
    }
}
