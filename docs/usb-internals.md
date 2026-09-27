# USB 라이브러리 형식과 쓰기 규칙

rekordbox 7이 USB에 내보내는 라이브러리(OneLibrary·Device Library)를 DJCrate가 읽고 쓰는 규칙이다. 로컬 rekordbox 라이브러리 쓰기는 `docs/rekordbox-internals.md`, 구조·설계 결정은 `docs/architecture.md`의 "USB" 절을 본다.

## 0. 읽는 법·근거 표기

## 1. USB 파일 목록

## 2. OneLibrary(exportLibrary.db)

## 3. Device Library(export.pdb·exportExt.pdb)

## 4. ANLZ 변환

로컬 분석 파일(`share` + `djmdContent.AnalysisDataPath`에서 확장자만 바꾼 `.DAT`·`.EXT`·`.2EX`)과 `djmdCue`로 USB 분석 파일 세 개를 만든다(`UsbAnlzTransform`). 로컬 파일 이름은 `ANLZ0000`이 아닐 수 있어 가정하지 않는다. 근거는 모두 rekordbox 7.2.18 골든 관찰이다. 골든의 곡을 로컬 곡과 짝지어 다시 만들면, 스냅샷을 뜬 뒤 로컬 분석 파일이 바뀐 곡을 빼고 세 파일이 바이트까지 같았다(§4.10). 모든 칸은 빅엔디언이다.

### 4.1 파일 머리

`PMAI` · len_header 28 · len_file(파일 전체 길이, 태그를 바꾼 뒤 다시 적는다) · 나머지 16바이트는 로컬 그대로.

### 4.2 태그 처리

태그 순서는 로컬 순서 그대로 두고, 태그 목록을 돌며 새 목록을 만든다. 같은 이름 태그(PCOB 둘, PCO2 둘)는 태그 0x0C의 목록 종류(1 핫큐, 0 메모리 큐)로 가린다. 골든에서 본 순서는 `.DAT` `PPTH PVBR PQTZ PWAV PWV2 PCOB(핫) PCOB(메모리)`, `.EXT` `PPTH PWV3 PCOB(핫) PCOB(메모리) PCO2(핫) PCO2(메모리) PQT2 PWV5 PWV4 [PVB2] [PSSI]`, `.2EX` `PPTH PWV7 PWV6 PWVC PVDI`다.

| 태그 | USB |
|---|---|
| 모든 파일 `PPTH` | `/Contents/…` 경로로 새로(§4.3) |
| `PVBR` `PQTZ` `PWAV` `PWV2` `PWV3` `PWV4` `PWV5` `PWV6` `PWV7` `PWVC` `PVB2`, 비지 않은 `PQT2`, 모르는 태그 | 바이트 그대로 |
| `.DAT` `PCOB` 둘, `.EXT` `PCOB` 둘·`PCO2` 둘 | `djmdCue`로 새로(§4.4–4.6). 로컬 share의 큐 태그는 비어 있다 |
| `.EXT` `PSSI` | 평문(mood 1–3)이면 마스크(§4.7). 이미 마스크된 모양이면 빼고 경고 `maskedLocalPSSIDropped` |
| `.2EX` `PVDI` | 평문이면 마스크(§4.8). 이미 마스크된 모양이면 그대로 두고 경고, 모르는 모양이면 그 자리에 빈 `PVDI`를 두고 경고. 없으면 빈 `PVDI`를 파일 끝에 붙인다 |
| `.EXT` 빈 `PQT2` | 뺀다(§4.9) |
| `.3EX` | 만들지 않는다 |

로컬 `.2EX`가 없으면 USB `.2EX`도 만들지 않는다(막는 것은 계획 몫). 경고는 `UsbAnlzWarning`의 코드로 남기고 계획 보고에서 문구로 바꾼다.

### 4.3 경로 태그(PPTH)

| 오프셋 | 칸 | 값 |
|---|---|---|
| 0x00 | `PPTH` | |
| 0x04 | len_header u32 | 0x10 |
| 0x08 | len_tag u32 | 0x10 + len_path |
| 0x0C | len_path u32 | 경로 바이트 수(UTF-16BE, 끝 NUL 2바이트 포함) |
| 0x10 | 경로 | `/Contents/{Artist}/{Album}/{File}` UTF-16BE + `00 00` |

로컬은 `?/{파일 이름}`이다. USB에서는 세 파일에 같은 경로를 쓰고, Device Library `file_path`·OneLibrary `path`와 글자까지 같다(NFC). 코드는 `AnlzPathTag`.

### 4.4 큐 배치·순서

입력은 `djmdCue`에서 그 곡의 `rb_local_deleted = 0`인 행이다(`UsbCueSource`, 배치는 `UsbCuePlacement`).

| 태그 | 넣는 큐 |
|---|---|
| `.DAT` PCOB(핫, 종류 1) | 핫큐 A–C(Kind 1·2·3) |
| `.DAT` PCOB(메모리, 종류 0) | 메모리 큐 전부(Kind 0) |
| `.EXT` PCOB(핫) | 핫큐 D–H(Kind 5–9) |
| `.EXT` PCOB(메모리) | 늘 비움 |
| `.EXT` PCO2(핫) | 핫큐 A–H 전부 |
| `.EXT` PCO2(메모리) | 메모리 큐 전부 |

- 핫큐 번호는 Kind < 4면 Kind, 5–9면 Kind − 1(A=1 … H=8). Kind 4는 어느 태그에도 넣지 않고 경고 `cueKindDropped`.
- 목록마다 `created_at` 내림차순, 같으면 `InMsec` 내림차순. `created_at`은 시각으로 풀어 비교한다(`YYYY-MM-DD HH:MM:SS.fff +00:00`, 밀리초·시간대를 뺀 형식도). 하나라도 풀지 못하면 그 목록은 글자로 비교하고 경고 `cueCreatedAtUnparsed`. 골든 전 곡의 큐 태그에서 맞았고, 행 순서(rowid) 내림차순 규칙과는 골든으로 가를 수 없었다.

### 4.5 PCOB·PCPT

PCOB 머리 24바이트: `PCOB` · len_header 0x18 · len_tag(24 + 56n) · 목록 종류 u32 · u16 0 · 항목 수 n u16 · u32(핫 `0xFFFFFFFF`, 메모리 n − 1, n = 0이면 `0xFFFFFFFF`). 빈 PCOB는 로컬 새 곡의 빈 태그와 같다.

| 오프셋 | 칸 | 값 |
|---|---|---|
| 0x00 | `PCPT` | |
| 0x04 | len_header u32 | 0x1C |
| 0x08 | len_entry u32 | 0x38 |
| 0x0C | hot_cue u32 | 메모리 0, 핫 1–8 |
| 0x10 | status u32 | 0(활성 루프도 0으로 쓴다 — 확인 안 된 모양은 `cueVariant`) |
| 0x14 | u32 | `0x00010000` |
| 0x18 | 앞 항목 u16 | 메모리 i − 1(첫 항목 `0xFFFF`), 핫 `0xFFFF` |
| 0x1A | 뒤 항목 u16 | 메모리 i + 1(끝 항목 `0xFFFF`), 핫 `0xFFFF` |
| 0x1C | type u8 | 1 큐, 2 루프(OutMsec > InMsec) |
| 0x1D | u8 | 0 |
| 0x1E | u16 | `0x03E8` |
| 0x20 | u32 | InMsec |
| 0x24 | u32 | 루프면 OutMsec, 아니면 `0xFFFFFFFF` |
| 0x28–0x37 | 16바이트 | 0 |

### 4.6 PCO2·PCP2

PCO2 머리 20바이트: `PCO2` · len_header 0x14 · len_tag · 목록 종류 u32 · 항목 수 u16 · u16 0.

| 오프셋 | 칸 | 값 |
|---|---|---|
| 0x00 | `PCP2` | |
| 0x04 | len_header u32 | 0x10 |
| 0x08 | len_entry u32 | 0x58 + len_comment |
| 0x0C | hot_cue u32 | 메모리 0, 핫 1–8 |
| 0x10 | type u8 | 1 큐, 2 루프 |
| 0x11 | u8 | 0 |
| 0x12 | u16 | `0x03E8` |
| 0x14 | u32 | InMsec |
| 0x18 | u32 | 루프면 OutMsec, 아니면 `0xFFFFFFFF` |
| 0x1C | 색 id u8 | 골든은 모두 0. 색 큐는 핫 `ColorTableIndex`, 메모리 `Color`(1–8, 그 밖 0)로 쓰되 확인 안 된 모양(`cueVariant`) |
| 0x1D | u8 | 1 |
| 0x1E | u16 | 0 |
| 0x20 | u32 | 0 |
| 0x24 | u16 | 박 루프 분자 = `BeatLoopSize >> 16`(NULL은 0) |
| 0x26 | u16 | 박 루프 분모 = `BeatLoopSize & 0xFFFF` |
| 0x28 | len_comment u32 | 주석 UTF-16BE 바이트 + NUL 2. 주석이 NULL·빈 글자면 0 |
| 0x2C | 주석 | UTF-16BE + `00 00`(패딩 없음) |
| C = 0x2C + len_comment | 색 4바이트 | 핫큐 `00 1A FF 00`, 핫 루프 `00 FF 8C 00`, 메모리 `00 00 00 00` |
| C + 0x04 | u64 | In 프레임 시작(FLAC만, `InPointSeekInfo` 첫 값) |
| C + 0x0C | u64 | Out 프레임 시작(FLAC 루프만, `OutPointSeekInfo` 첫 값) |
| C + 0x14 | u64 | In 바이트 위치(FLAC만, 둘째 값) |
| C + 0x1C | u64 | Out 바이트 위치(FLAC 루프만, 둘째 값) |
| C + 0x24 | u32 | In 블록 크기(FLAC만, 셋째 값) |
| C + 0x28 | u32 | Out 블록 크기(FLAC 루프만, 셋째 값) |

SeekInfo는 `"a,b,c"` 글자이고 `"0,0,0"`·NULL·빈 글자는 0으로 쓴다. 탐색 칸은 FLAC(`FileType` 5)만 채우고, M4A·MP3 CBR(`InMpegFrame` 0)은 모두 0으로 확인했다. 그 밖의 형식(VBR MP3, WAV, AIFF, ALAC 등)은 0으로 쓰되 `cueSeekFields`로 표시한다.

### 4.7 PSSI 마스크

로컬 평문 PSSI의 바이트 18부터 끝까지 `b[i] ^= (마스크[(i − 18) % 19] + 항목 수) & 0xFF`(항목 수 = u16 @0x10). 바이트 0–17은 그대로다. 마스크 상수는 `AnlzMasks.pssiMask`(pyrekordbox MIT의 XOR 규칙, 골든으로 다시 확인). 평문인지는 mood(u16 @0x12)가 1–3인지로 가린다. 로컬에 이미 마스크된 PSSI가 있으면 USB에서 빼고 경고한다.

### 4.8 PVDI 마스크

로컬 PVDI 머리 24바이트는 `PVDI` · len_header 0x18 · len_tag · `00 00 04 00` · `56 22 00 01` · 본문 길이 u32(= len_tag − 24)다. USB에서는 바이트 12를 `0x00` → `0x80`으로 바꾸고, 바이트 24부터 끝까지 `b[i] ^= 키[(i − 24) % 19]`를 한다. 키는 `AnlzMasks.pvdiKey`(골든과 로컬의 같은 곡 PVDI를 XOR해 얻은 관찰값, 길이와 관계없이 같다). 로컬에 PVDI가 없으면 `.2EX` 끝에 빈 PVDI(`AnlzMasks.emptyPVDI`: `PVDI` · 0x18 · 0x18 · `00 00 04 00` · `56 22 00 01` · 0, 플래그 0)를 붙인다. 로컬 PVDI의 바이트 12가 이미 `0x80`이면 그대로 옮기고 경고 `maskedLocalPVDIKept`(로컬에서 본 적 없는 모양). 24바이트보다 짧거나 바이트 12가 `0x00`·`0x80`이 아닌 PVDI는 마스크를 씌울 수도 그대로 옮길 수도 없어, 로컬에 PVDI가 없는 곡처럼 빈 PVDI를 두되 태그 순서를 지키려고 그 자리에 두고 경고 `unknownLocalPVDIDropped`.

### 4.9 빈 PQT2

len_tag 56이고 0x0C부터 `00 00 00 00 01 00 00 02`, 나머지가 0인 `PQT2`는 USB에서 뺀다. 비지 않은 `PQT2`는 그대로 둔다.

### 4.10 확인 안 된 규칙

변환 결과의 규칙 표시(`UsbAnlzResult.rules`)는 곡 큐 모양 분류(`UsbCueRules.rules`) 그대로다(§9 `cueVariant`·`cueSeekFields`). 실험 명령 `djc lab usb-anlz-check`는 USB 폴더의 분석 파일을 로컬 분석 파일·큐로 다시 만들어 바이트를 비교한다(모두 읽기만). 곡은 USB `PPTH` 경로의 음원 파일 이름·크기를 로컬 `djmdContent`의 (`FileNameL`, `FileSize`)와 맞춰 짝짓고, 맞는 로컬 곡이 하나가 아니면 짝 없음으로 센다. 라이브러리에 이름·크기가 같은 곡이 여럿이면 `--playlist <재생 목록 ID>`로 내보낸 재생 목록의 곡만 후보로 둔다. 스냅샷을 뜬 뒤 로컬 분석 파일이 바뀐 곡은 따로 센다.

## 5. 경로·음원·아트워크

## 6. 설정 파일

## 7. 쓰기 절차

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
