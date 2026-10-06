---
paths:
  - "Sources/DJCDomain/Usb/**"
  - "Sources/RekordboxKit/Usb/**"
  - "Sources/DJCStorage/Usb/**"
  - "Sources/djc/Commands/UsbCommands.swift"
  - "Sources/djc/Lab/Usb*.swift"
  - "Sources/DJCrate/Usb/**"
  - "Tests/**/Usb*"
  - "Tests/**/Pdb*"
  - "Tests/**/OneLibrary*"
---

# USB 라이브러리 코드를 고칠 때

- 먼저 `docs/usb-internals.md`를 읽는다.
- 이 파일은 USB 쓰기에 적용한다. `Sources/RekordboxKit/**`에는 `rekordbox-write.md`도 함께 걸린다. 로컬 rekordbox 라이브러리 쓰기는 `RekordboxWriter.write` 한 곳, USB 쓰기는 `UsbWriter.write` 한 곳이다. 둘을 섞지 않는다(USB 코드는 로컬 DB에 쓰지 않는다).
- 실물 USB 쓰기는 `UsbPhysicalWriteGate`(코드 관문 + 실험실 스위치·`--allow-physical` + 쓰기 금지 목록 + USB 메모리 + 허용 목록 + 이름 확인, `docs/usb-internals.md` §12)를 모두 지날 때만 한다. 시험·에이전트는 이 Mac에 꽂힌 실제 볼륨(`/Volumes/*`)에 쓰지 않는다(나열·읽기 전용 확인만). 실물 경로 시험은 가짜 볼륨 정보를 임시 폴더 루트에 주입하거나 `lab usb-image` 이미지로 한다. 디스크 이미지 도구는 **장치 번호를 우리가 방금 붙인 attach 결과에서만** 받고, 파티션·포맷 직전에 `hdiutil info`의 image-path가 그 이미지인지 다시 확인한다. BusProtocol "Disk Image"는 보조 조건일 뿐이다.
- 디스크 이미지 판정은 DiskArbitration `DADeviceModel == "Disk Image"` + `hdiutil info`에 그 장치의 이미지가 있음 + 그 image-path가 일반 파일, 셋 다일 때만 참이다(`DADeviceProtocol`은 "Virtual Interface"라 판정에 쓰지 않는다). 모르면 실물로 본다.
- 경로 비교는 `realpath(3)` 결과끼리만 한다(`UsbScratchRoots.realPath`). Foundation 경로 정규화(`resolvingSymlinksInPath`·`standardizedFileURL`)는 `/private`를 떼어 어긋나므로 쓰지 않는다.
- lab 명령이 받는 이미지·마운트 지점·USB 폴더·출력 폴더는 `UsbScratchPath.check`를 거친다(임시 폴더 아래만).
- 실물 관문의 거부 목록은 fail-closed다: 목록 파일이 깨졌거나(실물 쓰기가 열린 뒤에는 없거나 비었으면) 실물 쓰기를 막는다.
- 골든 대조는 lab 명령에서만, 사본으로 한다. 시험은 합성 자료만.
- 쓰기 파일은 `Sources/RekordboxKit/Usb/Write/`에 둔다(쓰기 커버리지 80%).
- 확인 안 된 규칙은 `UsbProvisionalRule`에 등록하고 계획에 싣는다. `confirmed`에 넣는 것은 rekordbox 실험 → 사본 재현 → 칸 단위 일치 → 골든 테스트를 거친 뒤다.
- 모르는 칸·고정 표를 "골든 바이트 상수"로 채우는 요령은 쓰지 않는다. 칸 단위 규칙이 우선한다. 관찰한 칸 하나의 고정값만 근거 주석을 단 이름 붙은 상수로 둔다.
- 새 칸을 쓰면 검증 쪽(다시 읽기 비교)도 함께 고친다.
