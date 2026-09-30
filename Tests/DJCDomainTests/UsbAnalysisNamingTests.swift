import DJCDomain
import Foundation
import Testing

@Suite("USB 분석 파일 폴더·번호")
struct UsbAnalysisNamingTests {
    @Test("DJCrate 고유 폴더 이름: P + 상위 12비트 3자리, content ID 8자리(16진)")
    func identifierFormat() {
        let naming = IdentifierAnalysisNaming()
        #expect(naming.folder(contentsPath: "/Contents/A/B/x.mp3", contentID: 1) == "P000/00000001")
        #expect(naming.folder(contentsPath: "/Contents/A/B/x.mp3", contentID: 0x12345) == "P012/00012345")
        #expect(naming.folder(contentsPath: "/Contents/A/B/x.mp3", contentID: 0xABCDEF) == "PABC/00ABCDEF")
    }

    @Test("고유 이름은 analysisFolderNaming 규칙을 싣는다")
    func ruleIsAnalysisFolderNaming() {
        #expect(IdentifierAnalysisNaming().rule == .analysisFolderNaming)
        let naming: any UsbAnalysisNaming = IdentifierAnalysisNaming()
        #expect(naming.rule == .analysisFolderNaming)
    }

    @Test("같은 곡 경로(PPTH)가 있으면 그 번호를 다시 쓴다")
    func slotReuseSamePPTH() {
        let existing = [(slot: 0, ppth: "/Contents/A/B/other.mp3"), (slot: 1, ppth: "/Contents/A/B/x.mp3")]
        let chosen = UsbAnalysisSlot.choose(existing: existing, contentsPath: "/Contents/A/B/x.mp3")
        #expect(chosen.slot == 1)
        #expect(chosen.reuse)
        // NFD로 적힌 경로도 같은 곡
        let nfd = UsbAnalysisSlot.choose(existing: [(slot: 2, ppth: "/Contents/A/B/Cafe\u{0301}.mp3")],
                                         contentsPath: "/Contents/A/B/Caf\u{00E9}.mp3")
        #expect(nfd.slot == 2 && nfd.reuse)
    }

    @Test("다른 곡 파일이 있으면 덮어쓰지 않고 가장 작은 빈 번호")
    func slotNextFreeWhenOtherPPTH() {
        #expect(UsbAnalysisSlot.choose(existing: [], contentsPath: "/Contents/x.mp3") == (slot: 0, reuse: false))
        let one = UsbAnalysisSlot.choose(existing: [(slot: 0, ppth: "/Contents/o.mp3")], contentsPath: "/Contents/x.mp3")
        #expect(one == (slot: 1, reuse: false))
        let two = UsbAnalysisSlot.choose(existing: [(slot: 0, ppth: "/Contents/o.mp3"), (slot: 1, ppth: "/Contents/p.mp3")],
                                         contentsPath: "/Contents/x.mp3")
        #expect(two == (slot: 2, reuse: false))
        let gap = UsbAnalysisSlot.choose(existing: [(slot: 1, ppth: "/Contents/p.mp3")], contentsPath: "/Contents/x.mp3")
        #expect(gap == (slot: 0, reuse: false))
    }

    @Test("파일 줄기와 경로는 번호를 16진 4자리로")
    func fileStemHex() {
        #expect(UsbAnalysisSlot.fileStem(slot: 0) == "ANLZ0000")
        #expect(UsbAnalysisSlot.fileStem(slot: 10) == "ANLZ000A")
        #expect(UsbAnalysisSlot.analysisPath(folder: "P000/00000001", slot: 10) == "/PIONEER/USBANLZ/P000/00000001/ANLZ000A.DAT")
    }
}
