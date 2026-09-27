# USB 라이브러리 형식과 쓰기 규칙

rekordbox 7이 USB에 내보내는 라이브러리(OneLibrary·Device Library)를 DJCrate가 읽고 쓰는 규칙이다. 로컬 rekordbox 라이브러리 쓰기는 `docs/rekordbox-internals.md`, 구조·설계 결정은 `docs/architecture.md`의 "USB" 절을 본다.

## 0. 읽는 법·근거 표기

## 1. USB 파일 목록

## 2. OneLibrary(exportLibrary.db)

## 3. Device Library(export.pdb·exportExt.pdb)

## 4. ANLZ 변환

## 5. 경로·음원·아트워크

## 6. 설정 파일

## 7. 쓰기 절차

USB에 쓰는 길은 `UsbWriter.write` 하나다. 되돌리기(`restore`, `djc usb-restore`)와 회복(`recover`, `djc usb-recover`)도 같은 확인을 먼저 거친다. 쓰기는 형식(OneLibrary·Device Library)을 모른 채 변경 묶음(`UsbChangeSet`: DB 교체·음원 복사·준비 파일 쓰기·지우기·목표 지문)을 파일 단위로 쓴다. 형식별 막힘과 검증은 주입한다(`UsbWriteInspector`·`UsbWriteVerifier`).

### 7.1 단계

| 단계 | 하는 일 | 실패하면 |
|---|---|---|
| A 막힘 확인 | 부작용 없음(7.2) | `writeRefused`. USB·백업·저널 그대로 |
| B 준비 | 준비 폴더 파일의 크기·해시가 계획과 같은지, 저널 `staged`. 드라이 런은 저널을 `dryRun`으로 닫고 끝 | 〃 |
| C 백업(Mac) | `usb-backups/<볼륨 UUID>/<시각>-<이름>/`에 DB·사이드카·`export.pdb.bak`, 덮어쓸 파일, 지울 파일(음원 빼고), 그 파일들의 원래 있던 `._`와 `manifest.json`. 파일마다 복사 전후 크기·mtime이 같아야 함. 저널 `backedUp`이 디스크에 내려간 뒤에만 D | 백업 폴더를 지우고 막음 |
| D 파일(취소 가능) | 음원 → 분석 파일 → 아트워크 → 그 밖. 없는 폴더는 위에서부터 한 단계씩 만들고 저널에 적음 | H |
| E DB 교체(커밋 지점) | exportLibrary.db → export.pdb → exportExt.pdb. DB 항목을 저널에 먼저 적고 임시 이름에 쓴 뒤 rename. OneLibrary는 rename 전에 USB의 `-wal`·`-shm`·`-journal`을 지움(백업에 있음) | H |
| F 지우기 | 지우기 허용 목록 + 크기·SHA-256 + 분석 파일은 PPTH가 계획과 같을 때만. 맞지 않으면 건너뛰고 알림(실패가 아님). 비게 된 우리 폴더만 지움 | H |
| G 검증 | 목표 지문(매체에서 다시 읽음)·없어야 할 경로·우리 폴더의 임시 파일 0개·이번에 바꾼 경로의 `._` 0개 + 주입한 검증 | H |
| H 되돌리기 | 7.6 | `restoreFailed`(백업 폴더와 `djc usb-restore` 안내) |
| I 끝 | 백업 폴더에 `report.json`(결과 DB SHA-256)·`journal.json`(닫는 저널 사본) → 백업 정리(7.9) → 저널 `verified` | — |

rekordbox·rekordboxAgent는 A, D 전, DB마다, F 전에 다시 본다. 켜져 있으면 멈추고 H로 간다.

### 7.2 A 막힘 확인 순서

1. **가드와 무관한 확인이 맨 처음이다.** 실물 쓰기가 닫혀 있는 동안(`UsbPhysicalWriteGate.buildEnabled == false`) 루트의 realpath(3)가 임시 폴더 뿌리 아래가 아니면 `physicalDisabled`로 끝낸다. 잠금 파일도 만들지 않고 USB 파일 연산도 하지 않는다. 주입한 가드가 "디스크 이미지"라고 해도 같다: 가드 값 하나가 거짓이면 관문과 가드 값 확인이 함께 뚫리기 때문이다. 디스크 이미지는 lab 도구·앱 자가 테스트가 늘 임시 폴더 아래에 붙이고, 실물은 `/Volumes` 아래에 붙는다. 이어서 루트가 정말 마운트 지점인지(statfs `f_mntonname` = realpath) 본다. 아니면 `notMountPoint`. 이 값을 기준 마운트 지점으로 기억한다(7.5).
2. 가드로 볼륨 정보를 읽는다(읽기만). 볼륨 UUID가 없으면 `noVolumeUUID`(잠금 전이라 잠금 파일이 생기지 않는다).
3. 잠금: `usb-sessions/<볼륨 UUID>.lock`에 `flock(LOCK_EX | LOCK_NB)`. 못 잡으면 `volumeBusy`. 쓰기·되돌리기·회복이 끝날 때까지 쥔다.
4. rekordbox 실행(`rekordboxRunning`), 볼륨 정책(`UsbVolumePolicy`)과 보호 경로(`protectedPath`), 실물 관문(`UsbRuleCheck`)과 가드 값이 실물이면 `physicalDisabled`.
5. 닫히지 않은 저널이 있으면 `recoveryNeeded`. 닫힌 상태는 `UsbJournal.closedStates` = verified·rolledBack·restored·recovered·dryRun·needsReplan 한 곳에 둔다. 드라이 런은 USB에 아무것도 쓰지 않으므로, needsReplan은 회복이 우리 임시 파일을 이미 지웠으므로 다음 쓰기를 막지 않는다. 저널 파일을 읽지 못하면 쓰기·되돌리기·회복 모두 `journalUnreadable`로 막는다(회복도 거부하므로 회복하라고 안내하지 않는다). 앱은 `UsbWriter.journalStatus`로 없음·열림·닫힘·깨짐을 가른다.
6. 우리 폴더(`PIONEER/rekordbox`, `PIONEER/USBANLZ`, `PIONEER/Artwork`, `Contents`)에 `.djc-part-*`가 있으면 `tempFilesPresent`(다른 Mac·다른 `DJC_HOME`의 쓰기 흔적). 이름만 본다.
7. 수정: 지금 DB 지문(크기·SHA-256, 사이드카 포함 — mtime은 FAT 2초 단위·복원 때 바뀌어 비교하지 않는다)이 계획 때 base와 같아야 한다. 아니면 `usbChanged`. 내보내기: `PIONEER/` 바로 아래에 `.`으로 시작하지 않는 이름이 없어야 한다(`notEmpty`). 개수는 바로 아래 이름만 세고 열지 않는 경로로 내려가지 않는다.
8. 형식 검사기(`UsbWriteInspector`)의 막힘. 10의 경로 막힘이 있으면 부르지 않는다(받을 수 없는 경로를 검사기가 읽지 않게).
9. 용량: 새로 쓸 크기(클러스터 단위 올림) + 가장 큰 DB × 2 + max(64 MiB, 가용 1%) − 지울 크기 ≤ 가용.
10. 대상 경로: 상대 경로, `..` 없음, 열지 않는 경로 아님, 부모 경로에 심볼릭 링크 없음. 모양 규칙(`UsbWriter.isSafeRelativePath`: 첫 성분 PIONEER·Contents, ""·"."·".." 성분 없음)은 되돌리기·회복이 기록을 읽을 때도 같이 쓴다. 세션 번호는 임시 이름이 되므로 영문·숫자·`-`·`_`만 받는다.
11. **만들 대상 충돌(`destinationExists`):** rename(2)은 대상이 있으면 조용히 바꿔치고, FAT(macOS msdos)는 대소문자·NFC/NFD만 다른 이름을 같은 이름으로 본다. 만들 파일·내보내기의 DB·새 폴더마다 부모 폴더 목록에 같은 `UsbLayout.collisionKey`의 이름이 있으면 막는다. 받을 수 없는 경로는 stat·열거하지 않고 건너뛴다(10이 막는다). 폴더는 NFC까지 같은 철자면 있는 폴더로 쓰고, 철자만 다르면 막는다. D 단계의 rename 직전에 한 번 더 본다. 그 사이 생긴 이름은 우리 것이 아니므로 H도 건드리지 않는다. 백업에도 없는 사용자 파일(예: `Contents/`에 직접 넣은 음원)을 잃지 않게 하는 규칙이다.

### 7.3 파일 하나 쓰기

- 임시 이름은 `UsbLayout.tempName(session:sequence:)`(같은 폴더, `.djc-part-…`)다. 대상 이름과 무관해 `._`·`_`로 시작하는 이름과 겹치지 않는다.
- 저널 항목(pending)을 먼저 적는다 → 데이터만 복사(`O_EXCL`, 확장 속성·ACL 없음) 또는 준비 파일 쓰기 → 음원·아트워크는 원본 mtime → `F_FULLFSYNC` → 덮어쓰기면 대상의 지금 SHA-256(분석 파일은 PPTH도)이 계획과 같은지, 만들기면 충돌 재확인 → rename → 정확한 이름 `._<대상>`·`._<임시>`만 지움 → 폴더 fsync → 저널 done.
- `._` 파일은 패턴으로 쓸지 않는다. 사용자의 `._` 파일은 남는다.
- `RENAME_SWAP`·`renamex_np`를 쓰지 않는다. FAT에서는 맞바꾸지 않고 덮어쓴다.
- 재사용은 쓰지 않고 크기와 내용 해시만 확인한다. 분석 파일·아트워크는 계획 SHA-256, 음원은 목표 지문의 SHA-256, 없으면 로컬 원본의 SHA-1과 비교한다. 음원에 둘 다 없을 때만 크기만 본다. 음원은 덮어쓰지 않는다.

### 7.4 Mac 쪽 내구 쓰기와 저널

- 저널·manifest·보고서는 같은 폴더 임시 파일 → write → `F_FULLFSYNC` → rename → 폴더 fsync로 쓴다(`UsbDurableFile`).
- 저널(`usb-sessions/<볼륨 UUID>.json`)은 파일·DB 항목(created·reused·overwritten, pending·done), 만든 폴더, 지운 사이드카, 지우기 상태(removed·skipped와 이유), 백업 폴더를 담는다. 상태 값은 `committing`·`committed` 하나씩이고, 형식별 진행은 DB 항목에서 읽는다(`committedFormats`·`committingFormat`).
- 저널 파일은 볼륨마다 하나라 새 세션(드라이 런 포함)이 닫힌 옛 저널을 덮는다. 그래서 되돌리기와 백업 정리는 백업 폴더의 `journal.json`·`report.json`을 읽는다.

### 7.5 마운트 확인과 볼륨이 사라질 때

- C 시작, D의 파일마다 쓰기 전과 rename 직전, E의 DB마다, F·G 전, H 시작과 H의 파일마다, 회복·되돌리기의 파일 연산 전에 루트가 아직 기준 마운트 지점에 붙어 있는지 본다.
- 실물은 뽑히면 마운트 폴더가 사라지지만, 디스크 이미지를 강제로 떼면 임시 폴더의 마운트 지점은 빈 폴더로 남는다. 확인 없이 이어 가면 USB가 아니라 Mac 폴더에 쓴다.
- 사라졌으면 그 자리에서 멈추고 되돌리지 않는다(`volumeLost`). 저널은 마지막 내구 상태 그대로 두고, 같은 볼륨이 다시 붙으면 회복이 이어 판정한다.

### 7.6 H 되돌리기

- 마운트 확인(사라졌으면 멈춤) → rekordbox 재확인(켜져 있으면 저널 `restorePending`) → pending 항목은 임시 이름만 지운다(대상 이름의 파일은 우리 것이 아닐 수 있다) → 만든 파일을 지운다(+ 정확한 `._`) → 덮어쓴 파일은 백업에서 임시 이름 → rename.
- DB는 저널의 DB 항목대로 한다. 쓰기 전에 없던 DB(내보내기)는 그 DB·`-wal`·`-shm`·`-journal`과 정확한 이름의 `._`만 지운다. 덮어쓴 DB(수정)는 USB 사이드카를 지우고 백업의 DB·사이드카·원래 있던 `._<DB>`를 되살린다.
- 지운 파일은 백업에서 되살린다. 지운 음원은 로컬 원본의 SHA-1이 같을 때만 다시 복사하고, 원본이 없거나 바뀌었으면 알림만 남기고 지문 비교에서 뺀다(되돌릴 수 없는 것을 실패로 세면 회복이 끝나지 않는다). 쓰기 전에 이미 없던 파일은 되살릴 것이 없다.
- 만든 폴더는 거꾸로 비었으면 지운다. 우리 경로 지문이 쓰기 전과 같으면 `rolledBack`, 아니면 `restoreFailed`.

### 7.7 회복(`djc usb-recover`) — 대상 먼저

- 쓰기와 같은 확인(7.2의 1–4, 관문 포함)을 먼저 거친다. 회복도 USB 파일을 지우고 이름을 바꾸는 쓰기다. 앱의 회복도 같다.
- 저널의 경로·임시 이름·세션이 7.2-10의 모양 규칙을 어기거나 백업 폴더가 이 볼륨의 `usb-backups/<볼륨>/` 밖이면 파일 연산 없이 `journalUnreadable`로 막는다. 없어진 백업 폴더는 없는 것으로 보고 기록을 새로 만들지 않는다.
- `usb-restore`가 연 저널(끊긴 되돌리기)은 되돌리기로 마저 하고 `restored`로 닫는다. 그 쓰기의 백업 기록은 바꾸지 않는다.
- DB마다 옛 해시·새 해시·없음·그 밖으로 나눈다. "그 밖"(기기가 바꿈)이 하나라도 있으면 저널에 적힌 우리 임시 파일만 지우고 `needsReplan`으로 닫는다. 다음 쓰기는 지금 USB를 다시 읽어 만든 새 계획이어야 한다(옛 계획은 `usbChanged`로 막힌다).
- 대상이 없고 임시 파일이 새 해시와 같으면 rename을 마친다(만들기는 충돌 재확인 뒤). 모든 DB가 새것이면 F·G를 다시 해 `recovered`. 일부만 바뀌었으면 준비 폴더가 온전하고 남은 DB가 옛것일 때 마저 쓰고, 아니면 H로 `rolledBack`.
- 저널에 적힌 임시 파일은 판정이 끝난 뒤 지운다. 저널이 없으면 USB의 `.djc-part-*`를 보고만 하고 `--discard-temp`일 때만 지운다.
- 닫을 때 그 쓰기의 백업 폴더에 `journal.json`·`report.json`(회복 뒤 지금 DB 해시)을 남긴다. 끊긴 쓰기도 백업 정리와 되돌리기가 알아보게 하려는 것이다. 백업 전에 끊겼으면(USB에 쓴 것 없음) 알림만 남긴다.

### 7.8 되돌리기(`djc usb-restore`)

- 같은 확인을 먼저 거친다. 무엇을 되돌릴지는 그 백업 폴더의 `journal.json`에서 읽는다. 백업 폴더는 realpath가 이 볼륨의 `usb-backups/<볼륨>/` 바로 아래여야 하고(`backupOutside`), `journal.json`·`manifest.json`의 경로가 7.2-10의 모양 규칙을 어기면 파일 연산 없이 `backupUnreadable`로 막는다.
- 되돌리기를 마치면 백업 폴더에 `restored.json`을 남긴다. 같은 백업으로 다시 되돌리면 "이미 되돌렸습니다"로 끝낸다(그 뒤 USB를 바꾼 것은 기기가 아니라 이 되돌리기다). `--backup`을 빼도 가장 최근 백업을 고르므로 두 번 돌려 더 옛 쓰기까지 되돌리지는 않는다.
- 지금 DB 해시가 `report.json`의 결과 해시와 같고 USB에 `-wal`·`-journal`이 없을 때만 진행한다. 아니면(기기가 쓴 기록 등) 막고, `--discard-device-changes`를 줘야 기기 변경을 버리고 되돌린다. 회복이 needsReplan으로 닫은 쓰기는 해시가 같아도 이 인자를 요구한다.
- 만든 파일·폴더·DB는 지우고, 덮어쓴 것은 백업에서 되살리고, 재사용한 것은 그대로 둔다. 지웠던 음원은 로컬 원본의 SHA-1이 manifest와 같을 때만 다시 복사한다. 그래서 내보내기 직후 되돌리면 빈 USB로 돌아간다.

### 7.9 백업 정리

볼륨마다 최근 다섯 개만 남긴다. 닫히지 않은 저널이 가리키는 백업, 마지막 verified 쓰기의 백업, 마지막 needsReplan 백업(다음 verified 전까지)은 남긴다. 판정은 백업 폴더의 `journal.json` 상태로 한다.

### 7.10 디스크 이미지(`djc lab usb-image`)

- 모든 경로 인자는 임시 폴더 아래만 받는다(`UsbScratchPath`). 경로 비교는 realpath(3)끼리 한다: `hdiutil info`의 image-path는 attach 때 준 철자 그대로라 `/tmp`와 `/private/tmp`가 섞인다.
- 만들기: sparse raw 파일 → MBR(파티션 하나, 2048섹터부터, 형식 0x0B 또는 0x0C) → `hdiutil attach -nomount` → 장치는 그 attach plist의 `content-hint`로 고른다(전체 `FDisk_partition_scheme`, 파티션 `DOS_FAT_32`·`Windows_FAT_32`, 배열 순서에 기대지 않는다) → 파괴 명령 직전 image-path·`BusProtocol == "Disk Image"`·`Internal == false`를 다시 확인 → `newfs_msdos -F 32` → 파티션 표 값만 확인(포맷 직후의 파일 시스템 이름은 비어 있거나 "MS-DOS"라 보지 않는다) → 떼고 BPB로 FAT32 판정(클러스터 수 ≥ 65,525).
- 클러스터: 파티션 8 GiB 이하는 4 KiB부터, 클러스터 수가 FAT32 최소에 모자라면 반으로 줄인다. 64 MiB보다 작은 이미지는 받지 않는다.
- hdiutil은 성공해도 stderr에 경고를 찍는다. 성공·실패는 rc와 stdout plist로만 판정한다.
- 붙이기는 `diskutil mount -mountOptions nobrowse -mountPoint`로 하고, 파일 시스템 이름이 "MS-DOS FAT32"로 보일 때까지 기다린다.
- 장치 번호는 인자로 받지 않는다. 늘 이미지 경로에서 `hdiutil info`로 찾는다. rekordbox가 켜져 있으면 만들기·붙이기·채우기·쓰기 시험을 거부한다.
- 볼륨이 디스크 이미지인지는 DiskArbitration `DADeviceModel == "Disk Image"`, `hdiutil info`의 짝, image-path가 일반 파일, 셋이 모두 맞을 때만 참이다. 모르면 실물로 본다. FAT32는 볼륨 종류·볼륨 형식("MS-DOS (FAT32)")·파티션 형식이 모두 맞을 때만이다(0x0B 파티션 안의 FAT16은 FAT16).

### 7.11 근거

디스크 이미지 강제 분리 시험(`djc lab usb-commit-crash`): 빈 FAT32 틀의 복제본에 합성 묶음을 쓰는 도중 무작위 시점에 강제로 떼고, 다시 붙여 원시 상태를 본 뒤 회복한다. 반복 시험에서 파일마다 옛것 또는 새것이었고, 회복 뒤 트리는 쓰기 전 또는 목표와 같았으며 분리 뒤 Mac 폴더에 쓴 흔적은 없었다.

## 8. USB 안 수정

## 9. 확인 안 된 규칙

| 규칙 | 지금 값 | 표시 조건 |
|---|---|---|
| `physicalVolume` | 확인 안 됨(관문으로만 풂) | 대상이 디스크 이미지가 아닌 실물 USB |
| `analysisFolderNaming` | 확인 안 됨 | 분석 파일을 USB에 새로 쓸 때 |
| `analysisSlotCollision` | 확인 안 됨 | 새 분석 파일 폴더 이름이 이미 있는 폴더와 겹칠 때 |
| `playlistSiblingBase` | 확인 안 됨 | 재생 목록을 쓸 때(같은 폴더 안 순서 번호) |
| `playlistFolderRow` | 확인 안 됨 | 재생 목록 폴더를 쓸 때 |
| `myTagLinks` | 확인 안 됨 | My Tag가 붙은 곡을 쓸 때 |
| `myTagMasterDBID` | 확인 안 됨 | My Tag를 쓸 때 |
| `artworkFolderSplit` | 확인 안 됨 | 아트워크를 여러 폴더로 나눠야 할 때 |
| `artworkMissing` | 확인 안 됨 | 아트워크가 없는 곡을 쓸 때 |
| `fileNameTruncation` | 확인 안 됨 | 음원 파일 이름을 줄여야 할 때 |
| `forbiddenCharacters` | 확인 안 됨 | 이름에 FAT에서 쓸 수 없는 글자가 있을 때 |
| `pathCollision` | 확인 안 됨 | 두 곡이 USB에서 같은 경로(대소문자·NFC/NFD 무시)가 될 때 |
| `emptyArtistAlbum` | 확인 안 됨 | 아티스트나 앨범이 빈 곡 |
| `supplementaryCharacters` | 확인 안 됨 | 이름에 이모지 등 보충 평면 글자가 있을 때 |
| `leadingSpace` | 확인 안 됨 | 이름이 빈칸으로 시작할 때 |
| `cueSeekFields` | 확인 안 됨 | 큐가 있는 곡의 음원 형식이 MP3(MPEG 프레임 칸 0)·M4A·FLAC가 아닐 때 |
| `cueVariant` | 확인 안 됨 | 색 핫큐, 색 메모리 큐, 메모리 루프, 활성 루프, 박 루프가 아닌 루프, 8·16박이 아닌 박 루프, 핫큐 D·F·G·H |
| `fileTypeUnverified` | 확인 안 됨 | 확인하지 않은 음원 형식의 곡 |
| `metadataSeenEmptyOnly` | 확인 안 됨 | 빈 값으로만 본 곡 정보 칸에 값이 있을 때 |
| `pdbLongAscii` | 확인 안 됨 | Device Library에 긴 ASCII 문자열을 쓸 때 |
| `pdbFarOffsetRows` | 확인 안 됨 | Device Library 행의 문자열이 행 머리에서 먼 곳에 놓일 때 |
| `carriedDeviceRows` | 확인 안 됨(디스크 이미지에도 막음) | USB에 기기가 남긴 기록 행이 있을 때 |
| `settingFiles` | 확인 안 됨 | 기기 설정 파일을 쓸 때 |
| `pdbRegeneratedEdit` | 확인 안 됨 | USB를 고치며 Device Library를 다시 만들 때 |
| `trackRemovalFiles` | 확인 안 됨 | USB에서 곡을 빼며 그 곡의 파일을 지울 때 |
| `editRefreshTracks` | 확인 안 됨 | USB 안 곡 정보를 갱신할 때 |
| `editRemoveTracks` | 확인 안 됨 | USB에서 곡을 뺄 때 |
| `editAddTracks` | 확인 안 됨 | 이미 내보낸 USB에 곡을 더할 때 |
| `editPlaylists` | 확인 안 됨 | 이미 내보낸 USB의 재생 목록을 고칠 때 |

## 10. 막아 둔 것

## 11. 새 USB 쓰기 경로를 여는 방법

rekordbox 실험 → 사본 재현 → 칸 단위 일치 → 골든 테스트 → `UsbProvisionalRule.confirmed`에 더함. 더한 뒤 §9 표의 지금 값을 고친다.
