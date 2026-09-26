import AppKit
import RekordboxKit

enum PreviewWaveformColorMode: String, Sendable {
    case blue
}

struct PreviewWaveformRequest: Hashable, Sendable {
    let url: URL?
    let revision: String
    let appearance: String
    var mode: PreviewWaveformColorMode = .blue
    var emphasized = false

    var cacheKey: NSString {
        [url?.absoluteString ?? "", revision, appearance, mode.rawValue, String(emphasized)]
            .joined(separator: "\u{1F}") as NSString
    }
}

/// 색 선택과 그리기를 한곳에 모으고, 셀에는 완성된 이미지만 넘긴다.
enum PreviewWaveformRenderer {
    static func image(_ waveform: AnlzPreviewWaveform, mode: PreviewWaveformColorMode,
                      appearance: String, emphasized: Bool = false) -> CGImage? {
        let width = 400, height = 40
        let heights = waveform.downsampled(to: width).heights
        guard !heights.isEmpty,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var color: NSColor
        switch mode {
        case .blue:
            color = UIColors.info.variants.resolved(for: NSAppearance.Name(appearance))
        }
        if emphasized, let appearance = NSAppearance(named: NSAppearance.Name(appearance)) {
            appearance.performAsCurrentDrawingAppearance {
                color = NSColor.alternateSelectedControlTextColor.usingColorSpace(.sRGB) ?? color
            }
        }
        context.setFillColor(color.cgColor)
        var bars: [CGRect] = []
        bars.reserveCapacity(heights.count)
        for (index, value) in heights.enumerated() where value > 0 {
            let x = index * width / heights.count, end = (index + 1) * width / heights.count
            let bar = max(1, Int(value) * height / 31)
            bars.append(CGRect(x: x, y: (height - bar) / 2, width: end - x, height: bar))
        }
        context.fill(bars)
        return context.makeImage()
    }
}

/// 파일 읽기와 비트맵 생성은 메인 액터 밖에서 직렬 처리한다. 빈 자료도 기억한다.
actor PreviewWaveformCache {
    static let shared = PreviewWaveformCache()
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

    func image(for request: PreviewWaveformRequest) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let hit = cache.object(forKey: request.cacheKey) { return hit.image }
        var image: CGImage?
        if let url = request.url, let file = try? AnlzFile(url: url),
           let waveform = try? AnlzPreviewWaveform(file: file), !Task.isCancelled {
            image = PreviewWaveformRenderer.image(waveform, mode: request.mode,
                                                 appearance: request.appearance, emphasized: request.emphasized)
        }
        guard !Task.isCancelled else { return nil }
        cache.setObject(Entry(image), forKey: request.cacheKey, cost: image.map { $0.bytesPerRow * $0.height } ?? 1)
        return image
    }
}

/// 재사용·모양새 전환 뒤 늦게 도착한 이미지는 버린다. 재생 틱은 읽지 않는다.
final class PreviewWaveformCell: NSTableCellView {
    private let waveformLayer = CALayer()
    private var source: (url: URL?, revision: String)?
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

    func configure(url: URL?, revision: String) {
        source = (url, revision)
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
                                          appearance: appearance.rawValue, emphasized: backgroundStyle == .emphasized)
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
