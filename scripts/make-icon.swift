// DJCrate 앱 아이콘을 그린다: 어두운 둥근 사각형 위, 레코드 세 장이 꽂힌 크레이트.
// 레코드 라벨은 덱 3밴드 파형 색(저역 파랑·중역 주황·고역 흰색)을 따른다.
// 사용: swift scripts/make-icon.swift <출력 .iconset 폴더> [미리 보기 .png]
import AppKit

let output = URL(filePath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: a) }

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let inset = s * 0.09
        let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let background = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
        NSGradient(starting: color(0.13, 0.14, 0.18), ending: color(0.04, 0.045, 0.06))?.draw(in: background, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        background.addClip()

        // 레코드: 크레이트 뒤에서 위로 비스듬히 솟은 원판 세 장
        let labels = [color(0.23, 0.44, 0.96), color(0.94, 0.64, 0.24), color(0.95, 0.94, 0.91)]
        let radius = rect.width * 0.25
        let crateTop = rect.minY + rect.height * 0.46
        let centers: [(CGFloat, CGFloat, CGFloat)] = [   // (x 비율, 위로 솟은 정도, 기울기 도)
            (0.30, 0.20, 10), (0.50, 0.26, 0), (0.70, 0.18, -10),
        ]
        for (i, c) in centers.enumerated() {
            let center = NSPoint(x: rect.minX + rect.width * c.0, y: crateTop + rect.height * c.1 - radius * 0.35)
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byDegrees: c.2)
            NSGraphicsContext.saveGraphicsState()
            transform.concat()
            let disc = NSBezierPath(ovalIn: NSRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
            NSGradient(starting: color(0.20, 0.20, 0.24), ending: color(0.06, 0.06, 0.08))?.draw(in: disc, angle: 60)
            // 가장자리 빛(어두운 배경에서 원판이 묻히지 않게)
            color(1, 1, 1, 0.22).setStroke()
            disc.lineWidth = max(1, s * 0.006)
            disc.stroke()
            // 홈(동심원)
            color(1, 1, 1, 0.07).setStroke()
            for k in 1...5 {
                let r = radius * (0.48 + 0.1 * CGFloat(k))
                let groove = NSBezierPath(ovalIn: NSRect(x: -r, y: -r, width: r * 2, height: r * 2))
                groove.lineWidth = max(0.5, s * 0.003)
                groove.stroke()
            }
            // 빛 반사
            let shine = NSBezierPath()
            shine.appendArc(withCenter: .zero, radius: radius * 0.86, startAngle: 100, endAngle: 150)
            shine.lineWidth = max(1, s * 0.012)
            color(1, 1, 1, 0.14).setStroke()
            shine.stroke()
            // 라벨과 가운데 구멍
            labels[i].setFill()
            NSBezierPath(ovalIn: NSRect(x: -radius * 0.36, y: -radius * 0.36, width: radius * 0.72, height: radius * 0.72)).fill()
            color(0.04, 0.045, 0.06).setFill()
            NSBezierPath(ovalIn: NSRect(x: -radius * 0.06, y: -radius * 0.06, width: radius * 0.12, height: radius * 0.12)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // 크레이트 앞판(주황 계열 나무 상자) + 손잡이 구멍 + 널빤지 줄
        let front = NSRect(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.12,
                           width: rect.width * 0.76, height: crateTop - rect.minY - rect.height * 0.12)
        let crate = NSBezierPath(roundedRect: front, xRadius: s * 0.035, yRadius: s * 0.035)
        NSGradient(starting: color(0.98, 0.62, 0.22), ending: color(0.86, 0.40, 0.10))?.draw(in: crate, angle: -90)
        color(0.55, 0.22, 0.04, 0.55).setFill()
        for k in 1...2 {
            let y = front.minY + front.height * CGFloat(k) / 3
            NSRect(x: front.minX + s * 0.02, y: y - s * 0.004, width: front.width - s * 0.04, height: s * 0.008).fill()
        }
        let handle = NSRect(x: front.midX - front.width * 0.17, y: front.maxY - front.height * 0.3,
                            width: front.width * 0.34, height: front.height * 0.14)
        color(0.30, 0.11, 0.02).setFill()
        NSBezierPath(roundedRect: handle, xRadius: handle.height / 2, yRadius: handle.height / 2).fill()
        // 윗면 테두리(앞판 위 밝은 선)
        color(1, 0.85, 0.6, 0.6).setFill()
        NSRect(x: front.minX + s * 0.02, y: front.maxY - s * 0.012, width: front.width - s * 0.04, height: s * 0.008).fill()
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("아이콘을 만들지 못했습니다") }
    return png
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: output.appending(path: "icon_\(base)x\(base).png"))
    try render(base * 2).write(to: output.appending(path: "icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 { try render(512).write(to: URL(filePath: CommandLine.arguments[2])) }
print("아이콘: \(output.path)")
