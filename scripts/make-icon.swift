// anicue 앱 아이콘을 그린다: 어두운 둥근 사각형 위 3밴드 파형(저역 파랑·중역 주황·고역 흰색)과 핫큐·메모리 큐 표시.
// 사용: swift scripts/make-icon.swift <출력 .iconset 폴더>
import AppKit

let output = URL(filePath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let inset = s * 0.09
        let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let background = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
        NSGradient(starting: NSColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1),
                   ending: NSColor(red: 0.03, green: 0.035, blue: 0.045, alpha: 1))?.draw(in: background, angle: -90)

        // 3밴드 파형(가운데 기준 대칭)
        let bands: [(NSColor, CGFloat)] = [
            (NSColor(red: 0.23, green: 0.44, blue: 0.96, alpha: 1), 1.0),
            (NSColor(red: 0.94, green: 0.64, blue: 0.24, alpha: 1), 0.72),
            (NSColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1), 0.42),
        ]
        let left = rect.minX + rect.width * 0.1, right = rect.maxX - rect.width * 0.1
        let midY = rect.midY - rect.height * 0.02
        let columns = 36
        let step = (right - left) / CGFloat(columns)
        for (color, scale) in bands {
            color.setFill()
            for i in 0..<columns {
                let t = Double(i) / Double(columns - 1)
                // 인트로 → 사비로 커지는 모양
                let envelope = 0.35 + 0.65 * (0.5 - 0.5 * cos(t * .pi * 2.2)) * (0.6 + 0.4 * t)
                let jitter = 0.75 + 0.25 * sin(Double(i) * 1.7) * sin(Double(i) * 0.61)
                let h = rect.height * 0.30 * CGFloat(envelope * jitter) * scale
                let bar = NSRect(x: left + CGFloat(i) * step + step * 0.12, y: midY - h, width: step * 0.76, height: h * 2)
                NSBezierPath(roundedRect: bar, xRadius: step * 0.3, yRadius: step * 0.3).fill()
            }
        }

        // 핫큐(초록)·메모리 큐(빨강) 선과 표시
        func marker(at x: CGFloat, color: NSColor, top: Bool) {
            color.setFill()
            NSRect(x: x - s * 0.006, y: rect.minY + rect.height * 0.12, width: s * 0.012, height: rect.height * 0.76).fill()
            let tri = NSBezierPath()
            let y = top ? rect.minY + rect.height * 0.88 : rect.minY + rect.height * 0.12
            let d: CGFloat = top ? -1 : 1
            tri.move(to: NSPoint(x: x - s * 0.04, y: y))
            tri.line(to: NSPoint(x: x + s * 0.04, y: y))
            tri.line(to: NSPoint(x: x, y: y + d * s * 0.06))
            tri.close()
            tri.fill()
        }
        marker(at: left + (right - left) * 0.3, color: NSColor(red: 0.94, green: 0.25, blue: 0.25, alpha: 1), top: true)
        marker(at: left + (right - left) * 0.68, color: NSColor(red: 0.16, green: 0.86, blue: 0.24, alpha: 1), top: false)
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
print("아이콘: \(output.path)")
