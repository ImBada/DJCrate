import Foundation

/// 계획이 필요로 하는 확인 안 된 규칙과 볼륨을 보고 쓰기 전 막힘을 낸다.
public enum UsbRuleCheck {
    /// required에 대해 막힘을 낸다. 실물이면 physicalVolume을 자동으로 더해 관문 결과를 합친다.
    /// 관문은 디스크 이미지에도 묻는다(거부 목록의 USB는 이미지여도 막는다. 그 밖에는 이미지를 통과시킨다).
    /// 실물 쓰기가 열려 있으면 흐름 규칙(`UsbProvisionalRule.openOnPhysical`)은 풀고, 그 밖의 규칙은 규칙마다 허용해야 한다.
    public static func blocks(required: Set<UsbProvisionalRule>, volume: UsbVolumeInfo,
                              allowProvisional: Set<UsbProvisionalRule>, gate: UsbPhysicalWriteGate,
                              confirmName: String?) -> [UsbBlock] {
        var result = gate.blocks(volume, confirmName: confirmName)
        for rule in UsbProvisionalRule.allCases where required.contains(rule) && !rule.isGateOnly {
            if rule.isConfirmed { continue }
            if !volume.isDiskImage, gate.isOpen, UsbProvisionalRule.openOnPhysical.contains(rule) { continue }
            if !rule.blocksEvenOnDiskImage {
                if volume.isDiskImage || allowProvisional.contains(rule) { continue }
            }
            result.append(UsbBlock(code: "provisional", scope: .volume,
                                   message: String(ui: "확인하지 않은 규칙(\(rule.summary))이 필요해 이 USB에 쓸 수 없습니다"),
                                   rule: rule))
        }
        return result
    }

    /// CLI `--allow-provisional a,b` 파싱. 모르는 이름·관문으로만 푸는 규칙은 거부한다.
    public static func parseAllowList(_ text: String) throws -> Set<UsbProvisionalRule> {
        var rules: Set<UsbProvisionalRule> = []
        for part in text.split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            guard let rule = UsbProvisionalRule(rawValue: name) else {
                throw UsbError.writeRefused([UsbBlock(code: "unknownRule", scope: .volume,
                                                      message: String(ui: "모르는 규칙 이름입니다(\(name)). 계획에 나온 규칙 이름을 쓰세요"))])
            }
            if rule.isGateOnly {
                throw UsbError.writeRefused([UsbBlock(code: "gateOnlyRule", scope: .volume,
                                                      message: String(ui: "\(name)은 --allow-provisional로 풀 수 없습니다"), rule: rule)])
            }
            rules.insert(rule)
        }
        return rules
    }
}
