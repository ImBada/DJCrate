# USB 라이브러리 형식과 쓰기 규칙

rekordbox 7이 USB에 내보내는 라이브러리(OneLibrary·Device Library)를 DJCrate가 읽고 쓰는 규칙이다. 로컬 rekordbox 라이브러리 쓰기는 `docs/rekordbox-internals.md`, 구조·설계 결정은 `docs/architecture.md`의 "USB" 절을 본다.

## 0. 읽는 법·근거 표기

## 1. USB 파일 목록

## 2. OneLibrary(exportLibrary.db)

근거: rekordbox 7.2.18 골든(2026-09-26 내보내기) 관찰.

### 2.1 파일·암호

- 위치 `PIONEER/rekordbox/exportLibrary.db`. SQLCipher 4 기본값 그대로다(cipher_page_size·page_size 4096, kdf_iter 256000, PBKDF2_HMAC_SHA512, HMAC_SHA512, 평문 머리 0 — 파일 첫 16바이트가 salt, 쪽마다 예약 80바이트). 따로 cipher PRAGMA를 주지 않는다.
- 키는 64자 영숫자 **문자열 키**다(`master.db`의 16진수 키와 다르다). `RekordboxKey.oneLibrary()`가 pyrekordbox(MIT)의 상수를 `master.db` 키와 같은 방법(base85 → XOR → zlib)으로 풀고, `CipherDatabase(path:key: .passphrase(…), mode:)`가 `PRAGMA key = '<키>'`로 넣는다. 키 글자는 `[A-Za-z0-9]`만 받는다. 키는 로그·출력·시험에 쓰지 않는다.
- rekordbox가 만든 파일은 journal_mode wal(머리 18·19바이트 = 2/2), user_version 0, application_id 0, auto_vacuum 0, UTF-8이고 트리거·뷰·AUTOINCREMENT, PK 말고 제약이 없다. 기기(OPUS-QUAD)가 연 뒤에는 롤백 모드(1/1)이고 SQLite 3.33.0 도장이 찍힌다. 두 모양 모두 읽는다.

### 2.2 스키마

표 22·인덱스 4를 아래 순서로 만든다. DDL 전체는 `Tests/Support/Resources/onelibrary-7.2.18-schema.sql`(rekordbox가 만든 `sqlite_master.sql`과 글자까지 같음), 코드는 `OneLibrarySchema`(칸 표 → DDL)다. 자료형은 소문자 `integer`·`varchar`이고 `integer primary key`만 rowid 별칭이다. 철자도 그대로 둔다: album `isComplation`, cue `OutFileOffsetInBlock`.

| 표 | 칸 수 | 표 | 칸 수 |
|---|---|---|---|
| content | 46 | hotCueBankList_cue | 3 |
| genre | 2 | history | 5 |
| artist | 3 | history_content | 3 |
| album | 6 | image | 2 |
| label | 2 | cue | 22 |
| key | 2 | menuItem | 3 |
| color | 2 | category | 4 |
| playlist | 6 | sort | 5 |
| playlist_content | 3 | property | 6 |
| hotCueBankList | 6 | recommendedLike | 4 |
| myTag | 5 | myTag_content | 2 |

인덱스: `playlist_content(playlist_id)`, `myTag_content(myTag_id)`, `myTag_content(content_id)`, `hotCueBankList_cue(hotCueBankList_id)`.

### 2.3 읽기 규칙

- USB 원본은 열지 않는다. 늘 `UsbSnapshot.take`로 뜬 사본에서 읽는다. 사본 폴더는 USB 밖(뿌리와 같거나 그 아래가 아님 — 링크를 풀고 장치·inode로 견줌)이고 비어 있거나 없어야 한다. 남은 `-wal`·`-shm`이 있으면 SQLite가 사본과 함께 집어 가기 때문이다.
  1. `PIONEER/rekordbox/`의 `exportLibrary.db`·`-wal`·`-shm`·`-journal`·`export.pdb`·`exportExt.pdb` 중 있는 것만 복사한다(본 DB가 없으면 사이드카는 복사하지 않음). 파일마다 복사 전후 크기·mtime이 같아야 하고(다르면 `sourceChangedDuringCopy`), 원본 크기·mtime·SHA-256을 지문(`UsbFingerprint`)에 남긴다. 링크·일반 파일이 아닌 것은 복사하지 않고 `readFailed`. 열지 않는 경로(`PIONEER/extracted`·`PIONEER/CDP`·`djprofile.nxs`)는 건드리지 않는다.
  2. `-shm` 사본은 지운다(SQLite가 WAL에서 다시 만든다).
  3. `-wal`이나 `-journal`이 있었으면 사본을 쓰기 가능하게 한 번 열어(`sqlite_master`를 읽으며 hot journal 롤백) `PRAGMA wal_checkpoint(TRUNCATE)` 뒤 닫는다. 롤백·WAL 복구는 쓰기 가능한 연결에서만 된다.
  4. 읽기 전용으로 다시 열어 `PRAGMA integrity_check` = "ok", `PRAGMA cipher_integrity_check` = 0줄이어야 한다(아니면 `readFailed`).
  5. 머리 18·19바이트는 암호화돼 직접 읽을 수 없어 `PRAGMA journal_mode`로 WAL·롤백 모양을 기록한다.
  - 어느 단계에서 멈춰도 뜬 사본과, 사본을 연 SQLite가 만든 사이드카를 지운다.
- 쓰기 가능한 연결로 여는 정리(3)는 방금 만든 사본에만 한다. 파일 하나를 사본으로 떠야 하는 실험 명령(`djc lab onelib-sql`)은 `UsbSnapshot.copyDatabase`로 db·`-wal`·`-journal`을 새 파일로 복사한 뒤 그 사본만 정리한다.
- 정수 칸은 64비트로 읽는다(My Tag ID·masterDbId·myTagMasterDBID가 2³¹을 넘을 수 있다).
- 모델에 담지 않는 표(cue·hotCueBankList·hotCueBankList_cue·recommendedLike)에 행이 있으면 표 위치와 행 수만 `unknownRows`에 남긴다(쓸 때 조용히 지우지 않게).

### 2.4 호환 검사

`OneLibraryCompatibility.check`는 표 22·인덱스 4가 정확히 있고, 표마다 칸 이름·선언 자료형·순서·기본 키, 인덱스마다 표·칸이 같고, 뷰·트리거가 없고, property가 한 행이며 `dbVersion` = "1000"이어야 통과시킨다. 아니면 `UsbError.formatUnsupported`로 읽지도 고치지도 않는다. SQLite는 `PRAGMA table_info`에서 표준 자료형 이름(integer)을 대문자로 돌려주므로 자료형은 대소문자만 빼고 비교한다.

기본 키 말고 제약은 없어야 한다. `table_info`의 NOT NULL·기본값이 비어 있어야 하고, `table_info`에 드러나지 않는 제약(CHECK·AUTOINCREMENT 등)은 `sqlite_master.sql`을 스키마 문장과 견줘(대소문자·빈칸 차이만 뺌) 본다. `sqlite_sequence`(AUTOINCREMENT)·`sqlite_autoindex_…`(UNIQUE 등)는 모르는 표·인덱스로 거부하고, ANALYZE 통계 표(`sqlite_stat…`)만 넘긴다.

### 2.5 칸 대응(모델 ← OneLibrary)

| 모델(`UsbTrack`) | content 칸 | 읽는 법 |
|---|---|---|
| id | content_id | |
| title / titleForSearch / subtitle | 같은 이름 | NULL → ""(titleForSearch는 nil 그대로) |
| bpmx100 / lengthSeconds / trackNo / discNo | bpmx100 / length(초) / trackNo / discNo | |
| artistID·remixerID·originalArtistID·composerID | artist_id_artist·_remixer·_originalArtist·_composer | NULL → nil |
| lyricistArtistID | artist_id_lyricist | 작사가 글자(`lyricist`)는 OneLibrary에 없어 "" |
| albumID·genreID·labelID·keyID / imageID | album_id·genre_id·label_id·key_id / image_id | NULL → nil |
| colorID | color_id | NULL → 0 |
| comment / rating / releaseYear / releaseDate / dateCreated / dateAdded | djComment / 같은 이름 | 날짜는 글자 그대로 |
| path / fileName / fileSize / fileType / bitrate / bitDepth / sampleRate / isrc | 같은 이름(sampleRate ← samplingRate) | |
| djPlayCount / hotCueAutoLoad / kuvoDeliver / kuvoDeliveryComment | djPlayCount / isHotCueAutoLoadOn(≠0) / isKuvoDeliverStatusOn(≠0) / kuvoDeliveryComment | |
| masterDbId / masterContentId | 같은 이름 | 64비트 |
| analysisDataPath / analysedBits / contentLink / hasModified | analysisDataFilePath / 같은 이름 | |
| 갱신 횟수 셋 | cueUpdateCount·analysisDataUpdateCount·informationUpdateCount | INTEGER → 10진 글자, TEXT '' → "", NULL → "" |
| deviceFields[.oneLibrary] | rating·djPlayCount·hasModified | 기기가 바꿀 수 있는 칸 |

그 밖: artist(name·nameForSearch), album(name·artist_id·image_id·isComplation·nameForSearch), genre·key·label·color(name), image(path → `oneLibraryPath`), playlist(sequenceNo → 형식별 순서, attribute, playlist_id_parent → parentID, image_id), playlist_content(sequenceNo 순 → 형식별 항목), myTag(attribute 1 = 분류, myTag_id_parent → parentID), myTag_content, menuItem(name을 감싼 U+FFFA·U+FFFB를 뗌), category·sort, property 한 행, history·history_content(sequenceNo 순).

### 2.6 두 형식 합치기·투영

- 모델(`UsbLibrary`)은 두 형식의 칸을 모두 담는다. 칸마다 그 값을 실제로 담는 형식과, 그 칸이 없는 형식의 리더가 넣는 기본값을 `UsbFieldFormats` 한 표에 둔다(예: `lyricist`·category `infoOrder`·`pdbDate`는 Device Library만, `titleForSearch`·album `imageID`·`createdDate`는 OneLibrary만).
- `UsbLibrary.merge`: 한 형식에만 있는 칸은 그 형식 값을 그대로 지킨다(다른 형식 리더의 빈 값으로 덮지 않고 비교도 하지 않음). 두 형식 모두의 칸은 OneLibrary 값이 앞서고 다르면 불일치로 보고한다. 같은 id인데 경로(NFC)가 다른 곡과 한 형식에만 있는 곡은 편집을 막는 불일치다.
- 같은 id 목록의 이름·부모·종류가 형식마다 다르면(`playlistConflict`) 합친 모델에는 OneLibrary 목록만 남는다. 그대로 고쳐 쓰면 Device Library 쪽 목록과 항목을 잃으므로 이것도 편집을 막는다.
- artist·album·genre·key·label·color·image·My Tag·menuItem·category·sort 행에는 형식별 소속이 없어 투영이 거를 수 없다. 한 형식에만 있는 행은 합집합에 두되 `sharedRowDiffers`로 보고한다(편집은 막지 않음).
- `projected(to:)`: 그 형식에 있는 곡·목록·My Tag 연결과 그 형식 몫(기록·항목·기기 칸)만 남기고, 그 형식이 담지 않는 칸은 그 형식 리더의 기본값으로 바꾼다. 불일치 없는 USB(위 보고가 하나도 없음)에서는 `merge(ol, dl).projected(to: .oneLibrary) == ol`이다. 쓰기·검증은 늘 형식별 투영과 비교한다(`UsbLibraryDiff`의 `formats`).
- `UsbLibraryDiff`와 `djc lab usb-diff`는 칸 이름·ID·수만 출력한다(제목·이름·경로 값은 찍지 않음). ID를 무시하고 견줄 때 이름(경로)이 같은 행이 여럿이면 나온 순서대로 짝짓는다.

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

USB `PIONEER/`의 `MYSETTING.DAT`·`MYSETTING2.DAT`·`DJMMYSETTING.DAT`는 기기(CDJ·DJM) 설정이다. rekordbox 내보내기는 로컬 rekordbox 설정 폴더의 같은 이름 파일을 옮겨 쓴다. 근거는 rekordbox 7.2.18 내보내기(2026-09-26) 관찰, 칸 뜻은 이슈 #45.

모양(리틀엔디언):

| 위치 | 칸 | MYSETTING·MYSETTING2 | DJMMYSETTING | DEVSETTING |
|---|---|---|---|---|
| 0x00 | 문자열 길이 u32 | 0x60 | 0x60 | 0x60 |
| 0x04 | 제조사 32바이트 | `PIONEER` | `PioneerDJ` | `PIONEER DJ` |
| 0x24 | 소프트웨어 32바이트 | `rekordbox` | `rekordbox` | `rekordbox` |
| 0x44 | 버전 32바이트 | `0.001` | `1.000` | 앱 버전 |
| 0x64 | 본문 길이 u32 | 40 | 52 | 32 |
| 0x68 | 본문 | MYSETTING은 `78 56 34 12 02 00 00 00`로 시작, MYSETTING2는 머리 표지 없음 | `78 56 34 12 01 00 00 00 20 00 00 00`로 시작 | `78 56 34 12 01 00 00 00`로 시작 |
| 끝−4 | CRC u16 | CRC-16/XMODEM(다항식 0x1021, 초깃값 0) | 같음 | 같음 |
| 끝−2 | u16 | 0 | 0 | 0 |
| CRC 범위 | | 본문(0x68 ~ 끝−4) | **파일 처음** ~ 끝−4 | 본문 |
| 크기 | | 148 | 160 | 140 |

뜻을 아는 칸(1바이트):

| 파일 | 위치 | 칸 |
|---|---|---|
| MYSETTING | 0x72 | quantize |
| MYSETTING | 0x80 | quantize beat value(0x80 1박 … 0x83 1/8박) |
| MYSETTING | 0x81 | hot cue auto load |
| MYSETTING2 | 0x74 | beat jump beat value |
| MYSETTING2 | 0x6D–0x6E | 뜻 모르는 새 칸. rekordbox 7.2.18 내보내기는 `80 80`, 옛 버전이 쓴 로컬 파일은 `00 00` |
| DJMMYSETTING | 0x78 | beat FX quantize |

규칙:

- 읽기 검증(`DeviceSettingFile`): 문자열 길이 = 0x60, 본문 길이 = 파일 크기 − 0x68 − 4, 크기가 종류별 값, 종류별 범위의 CRC 일치, 끝 2바이트 0. 하나라도 어긋나면 그 파일은 만들지 않는다.
- 고치기(`DeviceSettingPatch`): 구조체로 다시 만들지 않는다(모르는 칸이 0으로 지워진다). 읽은 바이트를 그대로 옮기고 아는 칸 바이트와 CRC만 덮은 뒤, 다시 읽어 검증한다.
- 내보내기용(`DeviceSettingPatch.forExport`): 머리 문자열·길이·본문은 그대로, MYSETTING2의 0x6D·0x6E가 둘 다 0이면 둘 다 0x80으로 채우고 CRC를 다시 계산한다(둘 다 0x80이면 그대로). 한쪽만 0이거나 다른 값이면 rekordbox가 쓴 적을 보지 못한 모양이라 그 파일을 만들지 않는다. 그 밖의 파일은 바이트가 바뀌지 않는다.
- 로컬 설정 폴더는 읽기만 하고, 세 파일 이름만 연다(폴더를 훑지 않는다).
- 첫 판 USB 내보내기는 설정 파일을 만들지 않는다. 이 코드는 선택으로 켜는 설정 옮기기용이다(기본 꺼짐). `DEVSETTING.DAT`(rekordbox 내보내기도 만들지 않음)·`djprofile.nxs`는 만들지 않는다.
- 실험: `djc lab setting-check <PIONEER 폴더>`(크기·길이·CRC 확인), `djc lab setting-export --local <로컬 설정 폴더> --out <빈 폴더>`(내보내기 모양으로 옮기기, 하나라도 만들지 못하면 실패로 끝남). USB 폴더와 출력 폴더는 임시 폴더 아래만 받는다.

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
