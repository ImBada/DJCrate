import DJCDomain
import DJCTestSupport
import Foundation
import Testing

@Suite("USB 볼륨 정책")
struct UsbVolumePolicyTests {
    func codes(_ volume: UsbVolumeInfo, _ purpose: UsbVolumePurpose = .export) -> [String] {
        UsbVolumePolicy.problems(volume, purpose: purpose).map(\.code)
    }

    @Test("디스크 이미지 FAT32·MBR은 내보낼 수 있다")
    func diskImageFAT32MBRPassesExport() {
        #expect(codes(FakeUsbVolume.diskImageFAT32()).isEmpty)
        #expect(codes(FakeUsbVolume.diskImageFAT32(), .edit).isEmpty)
    }

    @Test("실물 FAT32(파티션 형식 0x0B)는 통과")
    func physicalFAT32_0x0B_DOS_FAT_32Passes() {
        #expect(codes(FakeUsbVolume.physicalFAT32(content: "DOS_FAT_32")).isEmpty)
    }

    @Test("FAT32(파티션 형식 0x0C)도 통과")
    func windowsFAT32_0x0CPasses() {
        #expect(codes(FakeUsbVolume.windowsFAT32()).isEmpty)
    }

    @Test func fat16Blocked() {
        #expect(codes(FakeUsbVolume.fat16()) == ["notFAT32"])
        // 파일 시스템이 FAT32여도 파티션 형식이 FAT16이면 막는다.
        #expect(codes(FakeUsbVolume.physicalFAT32(content: "DOS_FAT_16")) == ["notFAT32"])
        // 파티션 형식을 모르면 막는다.
        var unknown = FakeUsbVolume.physicalFAT32()
        unknown.partitionContent = nil
        #expect(codes(unknown) == ["notFAT32"])
    }

    @Test func exfatBlocked() {
        #expect(codes(FakeUsbVolume.exfat()) == ["notFAT32"])
    }

    @Test func hfsPlusBlocked() {
        #expect(codes(FakeUsbVolume.hfsPlus()).contains("notFAT32"))
    }

    @Test func apfsBlocked() {
        #expect(codes(FakeUsbVolume.apfs()).contains("notFAT32"))
    }

    @Test func gptBlocked() {
        #expect(codes(FakeUsbVolume.gpt()).contains("notMBR"))
    }

    @Test func internalBlocked() {
        #expect(codes(FakeUsbVolume.internal()) == ["internal"])
    }

    @Test func networkBlocked() {
        #expect(codes(FakeUsbVolume.network()) == ["network"])
    }

    @Test func readOnlyBlocked() {
        #expect(codes(FakeUsbVolume.readOnly()) == ["readOnly"])
    }

    @Test func rootVolumeBlocked() {
        #expect(codes(FakeUsbVolume.rootVolume()) == ["rootVolume"])
    }

    @Test func notMountPointBlocked() {
        #expect(codes(FakeUsbVolume.notMountPoint()) == ["notMountPoint"])
        let problem = UsbVolumePolicy.problems(FakeUsbVolume.notMountPoint(), purpose: .export)[0]
        #expect(problem.message == "USB 볼륨의 맨 위 폴더를 고르세요")
    }

    @Test func secondPartitionBlocked() {
        #expect(codes(FakeUsbVolume.secondPartition()) == ["notFirstPartition"])
    }

    @Test func sector4096Blocked() {
        #expect(codes(FakeUsbVolume.sector4096()) == ["sectorSize"])
    }

    @Test("판정 순서대로 모두 낸다")
    func problemsFollowOrder() {
        var volume = FakeUsbVolume.gpt()
        volume.isReadOnly = true
        volume.fileSystem = .exfat
        volume.sectorSize = 4096
        #expect(codes(volume) == ["readOnly", "notMBR", "notFAT32", "notFirstPartition", "sectorSize"])
    }

    @Test("고칠 때는 다른 USB에 새로 내보내라고 안내한다")
    func editPurposeUsesReformatElsewhereMessage() {
        let edit = UsbVolumePolicy.problems(FakeUsbVolume.exfat(), purpose: .edit)
        #expect(edit.map(\.code) == ["notFAT32"])
        #expect(edit[0].message.contains("다른 USB에 새로 내보내세요"))
        #expect(edit[0].message.contains("exFAT"))
        #expect(!edit[0].message.contains("포맷한 뒤 다시 시도"))
        let export = UsbVolumePolicy.problems(FakeUsbVolume.exfat(), purpose: .export)
        #expect(export[0].message == "USB를 MBR·MS-DOS(FAT32)로 포맷한 뒤 다시 시도하세요")
        let gpt = UsbVolumePolicy.problems(FakeUsbVolume.gpt(), purpose: .edit)
        #expect(gpt.first { $0.code == "notMBR" }?.message.contains("다른 USB에 새로 내보내세요") == true)
    }

    @Test("고칠 때 문구는 파티션 형식을 읽을 수 있는 이름으로 적는다")
    func editPurposeNamesPartitionFormat() {
        func editMessage(_ volume: UsbVolumeInfo) -> String? {
            UsbVolumePolicy.problems(volume, purpose: .edit).first { $0.code == "notFAT32" }?.message
        }
        // 파일 시스템은 FAT32인데 파티션 형식을 모르면 "FAT32"라고 적지 않는다(스스로 어긋나는 문구).
        var unknown = FakeUsbVolume.physicalFAT32()
        unknown.partitionContent = nil
        let unknownMessage = editMessage(unknown)
        #expect(unknownMessage?.contains("알 수 없는 파티션 형식") == true)
        #expect(unknownMessage?.contains("(FAT32)") == false)
        // DiskArbitration 식별자 대신 형식 이름을 적는다.
        let fat16Message = editMessage(FakeUsbVolume.physicalFAT32(content: "DOS_FAT_16"))
        #expect(fat16Message?.contains("(FAT16)") == true)
        #expect(fat16Message?.contains("DOS_FAT_16") == false)
        #expect(editMessage(FakeUsbVolume.physicalFAT32(content: "Windows_FAT_16"))?.contains("(FAT16)") == true)
        #expect(editMessage(FakeUsbVolume.physicalFAT32(content: "DOS_FAT_12"))?.contains("(FAT12)") == true)
        #expect(editMessage(FakeUsbVolume.physicalFAT32(content: "Windows_NTFS"))?.contains("(exFAT/NTFS)") == true)
        // 파일 시스템이 FAT32가 아니면 파일 시스템 이름을 적는다.
        #expect(editMessage(FakeUsbVolume.fat16())?.contains("(FAT16)") == true)
    }

    @Test("읽기는 모든 모양을 허용한다")
    func readPurposeHasNoProblems() {
        let volumes = [FakeUsbVolume.exfat(), FakeUsbVolume.gpt(), FakeUsbVolume.internal(), FakeUsbVolume.readOnly(),
                       FakeUsbVolume.notMountPoint(), FakeUsbVolume.sector4096(), FakeUsbVolume.apfs()]
        for volume in volumes {
            #expect(UsbVolumePolicy.problems(volume, purpose: .read).isEmpty)
        }
    }

    @Test("막힘은 볼륨 범위로 같은 code·문구를 쓴다")
    func blocksMirrorProblems() {
        let blocks = UsbVolumePolicy.blocks(FakeUsbVolume.readOnly(), purpose: .export)
        #expect(blocks.map(\.code) == ["readOnly"])
        #expect(blocks[0].scope == .volume)
        #expect(blocks[0].message == "USB가 읽기 전용으로 연결됐습니다. 잠금 스위치를 풀고 다시 연결하세요")
        #expect(blocks[0].rule == nil)
    }
}
