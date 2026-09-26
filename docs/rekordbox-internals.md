# rekordbox 7 내부 형식 — DJCrate가 알아낸 쓰기 규칙

rekordbox 7.2.18에서 사용자가 직접 편집한 결과를 스냅샷끼리 diff해서 뽑은 규칙이다. 각 규칙은 "실험 전 사본에 DJCrate로 같은 편집을 쓰고, rekordbox가 쓴 결과와 칸마다 비교"해서 확인했다. 확인하지 못한 규칙은 코드에서 막아 두었다(아래 "막아 둔 것").

코드: `Sources/RekordboxKit/` — `RekordboxWriter`(DB, 역할별 `+Cues`·`+Grid`·`+Gain`·`+Analysis`·`+Verify`·`+Backup`), `RekordboxGridWriter`(ANLZ), `RekordboxCompatibility`(쓰기 전 버전·구조 확인), `CueJSON`, `AnlzFile`, `SeekInfo`, `CipherDatabase`.

## 파일과 열기

- 라이브러리: `~/Library/Pioneer/rekordbox/master.db` (SQLCipher 4). 키는 pyrekordbox와 같은 방식으로 푼다(`RekordboxKey.derive()`).
- 분석 파일: `~/Library/Pioneer/rekordbox/share/PIONEER/USBANLZ/<3자리>/<uuid 나머지>/ANLZ0000.{DAT,EXT,2EX,3EX}`. 경로는 `djmdContent.AnalysisDataPath`(`.DAT` 경로).
- 삭제 행이 절반쯤 있다(`rb_local_deleted=1`). 집계·쓰기는 항상 삭제되지 않은 행만.
- `agentRegistry`에는 클라우드 인증값이 들어 있다. 읽거나 출력하지 않는다(`djc lab sql`은 이 테이블 질의를 막는다). 예외: 쓰기 모듈이 `localUpdateCount`를 읽고 쓰고, `lastUpdateCount`의 정수 칸만 읽는다.

## 쓰기 전 확인 (`RekordboxCompatibility`)

쓰기 규칙은 rekordbox 7.2.18에서 확인했다. rekordbox가 업데이트로 DB 구조를 바꾸면 규칙이 맞지 않을 수 있어서, 쓰기 전에 다음을 보고 하나라도 다르면 **백업도 뜨지 않고** 막는다.

- 앱 버전: `/Applications/rekordbox N/rekordbox.app`의 `CFBundleShortVersionString` 주.부가 `7.2`(못 찾으면 아래 DB 검사에 맡김). 라이브 DB에만 적용.
- 새 행을 넣는 표(`djmdCue` 29칸, `contentCue` 13칸, 곡 넣기의 `djmdContent`·`djmdArtist`·`djmdAlbum`·`djmdGenre`, 곡 넣기·분석 붙이기의 `contentFile` 24칸·`djmdMixerParam` 15칸)는 칸 이름이 정확히 같아야 한다. 칸이 늘면 rekordbox가 기대하는 값을 빠뜨리게 된다.
- 고치거나 읽는 칸(`agentRegistry`·`djmdProperty`·곡 삭제의 `djmdSongPlaylist`·`djmdSongHistory`)은 모두 있어야 한다.
- `djmdProperty.DBVersion` = `6000`.
- `localUpdateCount` ≥ `lastUpdateCount`(클라우드 동기화가 본 가장 큰 번호). 로컬 번호가 더 작으면 동기화 때 변경이 되돌려졌다는 사례가 있다(2026-09-26 조사). 2026-09-26 실제 라이브러리: 로컬 1,002,950 · 클라우드 372,628.

`djc compat`으로 읽기 전용 확인을 할 수 있다. 새 rekordbox 버전을 허용하려면 "새 쓰기 경로를 여는 방법"처럼 실험으로 큐·그리드·게인 쓰기를 다시 확인한 뒤 `verifiedAppVersions`를 넓힌다.

## 공통: 변경 번호(usn)

- 바뀐 행마다 `rb_local_usn` = `agentRegistry`의 `localUpdateCount`를 1씩 올린 값. 마지막 값을 `localUpdateCount`에 적는다.
- `rb_data_status` 256 → 257 (이미 257이면 그대로). `updated_at`은 `YYYY-MM-DD HH:MM:SS.sss +00:00`.
- 한 곡의 큐를 바꾸면 `contentCue` 먼저, `djmdContent` 다음(연속 번호).

## 큐 (`djmdCue` + `contentCue`)

- 바꾼 큐는 행을 지우고 새로 넣는다. 새 `ID` = 겹치지 않는 임의 UInt32(문자열), `UUID` = 소문자 UUID.
- `InMsec` = ms, `InFrame` = ms × 150 / 1000(내림). 루프가 아니면 `OutMsec` −1, `OutFrame` 0.
- 루프가 아닌 새 큐: `Color` −1, `ColorTableIndex`·`ActiveLoop`·`BeatLoopSize`·`CueMicrosec` NULL, 코멘트 없으면 `Comment` NULL.
- `Kind`: 메모리 0, 핫큐 A·B·C = 1·2·3, D~H = 5~9. Kind 4는 뜻을 몰라 편집 대상에서 뺀다.
- 한도: 메모리 큐 곡당 10개(자동 큐 "1.1Bars" 포함). 핫큐 칸은 곡당 하나씩.
- `contentCue.Cues`는 곡의 모든 큐를 담은 JSON 배열이다.
  - 원래 객체는 **읽은 칸 순서 그대로** 다시 쓴다(옛 rekordbox가 쓴 순서가 다름).
  - 새 객체는 끝에 붙이고 칸 순서는 `ID, ContentID, ContentUUID, InMsec, InFrame, InMpegFrame, InMpegAbs, InPointSeekInfo, OutMsec, OutFrame, OutMpegFrame, OutMpegAbs, OutPointSeekInfo, Kind, Color, ColorTableIndex, ActiveLoop, Comment, BeatLoopSize, CueMicrosec, UUID, created_at, updated_at`.
  - NULL 칸과 빈 코멘트(`""`)는 적지 않는다(라이브러리 JSON에 `"Comment":""`는 0건). 시각은 `2026-09-25T20:20:39.744+00:00`.
  - `rb_cue_count` = 객체 수. `contentCue` 행이 없던 곡은 `ID` = 곡 UUID로 새로 만든다.
- `djmdContent.CueUpdated`(글자형) += 지운 수 + 넣은 수. NULL이면 0부터.

### 루프 (2026-09-26, Flip Flop·ときめき分類学 실험 + 기존 루프 105개)

- `OutMsec` = 끝 ms, `OutFrame` = 끝 ms × 150 / 1000(내림).
- `Color` 255, `ColorTableIndex` 0, `ActiveLoop` 0/1(활성 루프 = 곡을 불러오면 자동으로 반복), `CueMicrosec` 0, `Comment` `''`(JSON에는 안 적음).
- `BeatLoopSize` = 분자 << 16 | 분모. 8박 524289, 16박 1048577, ½박 65538, 박에 맞지 않는 루프 0.
- 새로 만든 루프는 JSON에도 `ActiveLoop`·`BeatLoopSize`가 있다(옛 루프 JSON엔 빠진 경우가 있음).
- 활성 루프는 곡당 하나(라이브러리에 둘 이상인 곡 없음). rekordbox는 활성 켜기를 행 제자리 UPDATE로 하고 `CueUpdated`를 안 올리지만, DJCrate는 지우고 새로 넣는다(결과 상태는 같음).

### 파일 형식별 탐색 위치

- MP3 CBR·M4A·WAV: `InMpegFrame`·`InMpegAbs` 0, SeekInfo NULL.
- FLAC: `InPointSeekInfo` = `"<큐 샘플이 든 FLAC 프레임 시작 샘플>,<그 프레임 바이트 위치 − 첫 오디오 프레임 위치>,<블록 크기>"`. 루프가 아니면 `OutPointSeekInfo` = `"0,0,0"`, 루프면 끝 지점을 같은 식으로. 기존 큐 1,818개·루프 끝 전부와 일치.
- VBR MP3(파일 머리가 Xing·VBRI거나 프레임 길이가 들쭉날쭉): `InMpegFrame` = InFrame / 2(1/75초 단위), `InMpegAbs` = rekordbox가 세는 프레임(LAME 정보 프레임은 세고 다른 인코더의 정보 프레임은 뺌) 중
  `floor(올림(InMpegFrame × 1000 / 75)ms × 샘플레이트 / 1000 / 1152) − 8`번째(음수면 0번째) 프레임의 바이트 위치(첫 센 프레임 기준). 루프 끝도 같은 식, 루프가 아니면 끝은 0·0. SeekInfo는 NULL.
  ms를 버림하면 1,099개, 올림하면 1,118개 전부 맞는다(기존 VBR 큐 1,118개·루프 끝 6개, `djc lab seekinfo-check`). 사본에서 VBR 200곡의 큐 886개를 지우고 다시 써도 885개가 칸까지 같다(`djc lab vbr-cue-repro`, 나머지 1개는 rekordbox가 옛날에 MPEG 칸을 비워 둔 큐).

## 비트그리드 (ANLZ)

- `.DAT`의 `PQTZ`: 박마다 `박 번호(u16 1~4) · BPM×100(u16) · 시각 ms(u32)`. 시각은 정밀 시각을 **내림**, 곡 앞 −1ms 안의 박은 0.
- `.EXT`의 `PQT2`: 머리에 첫 박·마지막 박·박 수·정체 모를 u32, 본문은 박마다 (ms 아래 소수 × 1024). rekordbox가 그리드를 손으로 고치면 PQT2를 빈 형태(머리 0·본문 없음)로 바꾼다 → DJCrate도 그렇게 쓴다.
- 이동만 하면 DB는 안 바뀐다(`contentFile` 해시도 그대로).
- BPM을 바꾸면:
  - `.DAT`의 `contentFile` 행: `Hash`(새 파일 MD5), `Size`, `rb_data_status`, `rb_local_usn`, `updated_at`.
  - `djmdContent`: `BPM`(×100), `AnalysisUpdated`+1·`TrackInfoUpdated`+1(글자형), 상태, usn.
  - 소수(PQT2)가 없으면 첫 박을 ms + 0.5로 보고 다시 계산한다(바이트까지 재현).
- 다른 태그는 바이트 그대로 둔다(`AnlzFile`이 태그 단위로 읽고 PMAI 전체 길이만 다시 적는다).
- **파형 파일(.EXT)이 없는 곡은 rekordbox 분석 전 곡이다**(BPM 0, PQTZ 0박). 그리드만 쓰면 파형 없는 채로 남으므로 막는다(2026-09-26 サラマンダー).
  분석 파일이 아예 없는 곡은 분석 붙이기로 쓰고(아래 "분석 붙이기"), `.DAT`만 있는 반쪽 곡은 "rekordbox에서 트랙 분석을 다시 한 뒤 쓰세요"로 막는다.

## 오토게인 (`djmdMixerParam`)

- `GainHigh`·`GainLow` = 선형 게인 float32의 상위·하위 16비트. `PeakHigh`·`PeakLow`는 샘플 피크.
- rekordbox 편집 시 삭제되지 않은 행 하나의 `GainHigh`·`GainLow`·상태·usn·`updated_at`만 바뀐다(같은 곡의 삭제된 옛 행이 따로 있을 수 있음).
- rekordbox는 약 −10 LUFS에 맞춘다: 게인 dB + 곡 LUFS = −9.97 ± 0.25.

## 시간축

- rekordbox는 압축 음원 앞 지연을 잘라 내지 않는다 → rekordbox 시각 = AVFoundation 시각 + 인코더 지연.
- AAC 2112샘플, LAME MP3 +51.2ms(576+529+1152), ffmpeg MP3 = 프라이밍+529, 태그 없는 MP3 529샘플, 무손실 0.
- 계산: `RekordboxTimeline.predictedOffset(url:)`. 덱·초안의 모든 시각은 rekordbox 시간축이다.

## 쓰기 절차 (`RekordboxWriter.write`)

1. rekordbox·rekordboxAgent가 실행 중이면 거부. `-wal`이 남아 있어도 거부.
2. master.db(+wal/shm) 전체와 바꿀 분석 파일을 `rekordbox-backups/<시각>-write/`에 복사(복사 중 원본이 바뀌면 실패).
3. `BEGIN IMMEDIATE` 한 트랜잭션에서 쓰고, 같은 연결로 다시 읽어 초안과 칸마다 비교. 비교 기준은 초안의 변경(`CueDraft.changes`, 1ms 미만 차이는 변경 아님)만 base에 반영한 큐 목록(`expectedCues(after:)`)이다. 그리드 따라가기로 1ms 미만 움직인 큐는 rekordbox 값 그대로 둔다(#73).
4. 커밋 뒤 다시 열어 한 번 더 검증 + `PRAGMA quick_check` + `cipher_integrity_check`.
5. 어느 단계든 실패하면 백업으로 되돌린다. 초안을 만든 뒤 rekordbox에서 그 곡이 바뀌었으면(base 불일치) 그 곡은 쓰지 않는다.

## 곡 추가·삭제 (`RekordboxTrackWriter`, 2026-09-26 묶음 1·2 실험)

**추가(분석 전)**: rekordbox가 자동 분석을 끈 채 파일을 넣으면 `djmdContent` 행 하나만 생긴다(78칸, 형식까지 `RekordboxTrackWriter.contentRow`).
- 곡 ID는 1~2^28 난수(라이브러리 14,155행 전부 이 범위), 아티스트·앨범·장르 ID는 32비트 난수. UUID는 소문자 v4.
- 태그(ID3·iTunes·Vorbis)에서 제목·아티스트·앨범·앨범 아티스트·장르·작곡가(`djmdArtist`)·코멘트·연도·트랙·디스크·ISRC. 제목이 없으면 확장자를 뺀 파일 이름. 설명이 붙은 ID3 코멘트(iTunNORM 등)는 쓰지 않는다. 이름이 없으면 새 행.
- 분석 칸은 0·빈 값, `Analysed` 0, `ContentLink` 14, `AnalysisUpdated`·`TrackInfoUpdated`·`CueUpdated` NULL, 길이는 초 반올림.
- `rb_file_id` = 음원 파일 inode, `DateCreated` = 파일 만든 날, `StockDate` = 넣은 날, `MasterDBID`·`DeviceID`는 라이브러리 공통값. 경로·파일 이름은 NFC.
- 변경 번호는 관련 행(아티스트·앨범·장르)이 먼저, 곡 행이 마지막.

**추가(분석 포함)**: 위 행에 분석 칸을 채우고 분석 파일·파일 행·오토게인 행을 더한다.
- 분석 경로 `/PIONEER/USBANLZ/<UUID 앞 3자>/<나머지>/ANLZ0000.DAT`, `Analysed` 105, 길이는 초 버림, `AnalysisUpdated` "3"·`TrackInfoUpdated` "2"(글자).
- 비트레이트: CBR MP3는 프레임 비트레이트, LAME VBR MP3는 0, AAC는 esds 평균 비트레이트(없으면 0, streamType 바이트 0x14도 있음), WAV는 샘플레이트×비트×채널, FLAC 0.
- `.DAT`: `PPTH`(`?/파일 이름` UTF-16BE + NULL) · `PVBR`(머리 0, 탐색표 400칸, 끝값 = MP3는 rekordbox가 세는 프레임 수×1152, AAC·WAV는 0) · `PQTZ` · `PWAV` · `PWV2` · `PCOB`(핫, 빈) · `PCOB`(메모리, 빈). 같은 그리드로 다시 만들면 머리·PPTH·PVBR·PQTZ·PCOB가 바이트까지 같다.
- `.EXT`·`.2EX`는 파형 생성기(`RekordboxWaveforms`, baken MIT 규칙 이식). 흑백 파형 높이는 99.5% 바이트 일치, 색·3밴드·미리 보기는 근사. rekordbox 7.2.18은 우리 파일을 그대로 표시했다(サラマンダー 복사본).
- `contentFile` 행은 파일마다(ID `<곡 UUID>_<경로, /는 %2F>`, MD5, 크기, `rb_local_path`, `rb_priority` 50). 없어도 표시는 되지만 rekordbox처럼 넣는다.
- 변경 번호: 관련 행 → (아트워크 파일 행) → 오토게인 행 → 곡 행 → .2EX → .DAT → .EXT. rekordbox는 곡 행을 먼저 넣고 분석이 끝나면 다시 고쳐 새 번호를 받고, 곡 행 뒤·.2EX 앞에 .3EX 행도 넣는다(2026-09-26 아트워크 실험 세션: 자동 분석을 켜고 넣은 합성 WAV 3곡, 분석 전 곡을 분석한 "DJC 실험 아트"). DJCrate는 곡 행을 한 번만 넣으므로 rekordbox의 마지막 번호 순서를 따른다.
- 같은 세션에서 rekordbox가 분석한 곡 4개는 `AnalysisUpdated`·`TrackInfoUpdated`가 '1'·'1'이었다(묶음 2의 '3'·'2', 분석 붙이기 실험의 '2'·'1'과 다름). 무엇이 이 값을 정하는지는 모른다. 쓰는 값은 바꾸지 않았다.
- `ContentLink`는 분석 구성 비트: `0x3C060E` 보통(6,409곡), `0x2C060E` 보컬 분석 없음, +`0x10000` 프레이즈 있음. 우리는 프레이즈·보컬이 없으므로 `0x2C060E`.
- 만들 수 없는 것: `PSSI`(프레이즈), `PVDI`(보컬), `.3EX`(MessagePack `embedding`, rekordbox AI 특징값). rekordbox에서 Phrase만 분석하면 우리 태그를 바이트 그대로 두고 `PSSI`만 덧붙인다.
- MP3 프레임 세기: LAME 정보 프레임(첫 프레임 안에 LAME 태그)은 소리로 세고, 다른 인코더(ffmpeg Lavc 등)의 정보 프레임은 세지 않는다. 다음 오디오 프레임에 "LAME3.99U"가 찍힌 ffmpeg 파일이 있어 LAME은 첫 프레임 안에서만 찾는다.
- VBR MP3 탐색표: 칸 k = 센 프레임 중 `floor((k+1)·n/400) − 8`번째 프레임의 바이트 위치(첫 센 프레임 기준, 음수면 0번째). 라이브러리 LAME VBR 451곡 400칸 전부 일치(CBR은 전부 0, 2291/2294곡). 8프레임 앞은 디코더 비트 저장소 몫으로 보인다.
- FLAC: 비트레이트 0, 비트는 STREAMINFO, `PVBR`은 탐색표·끝값 모두 0. 대신 `.EXT` 끝(`PWV4` 뒤)에 `PVB2`를 붙인다.
  머리 0x20(`u32 0` · `u64 전체 샘플` · `u32 400` · `u32 20`), 칸 400개 × 20바이트 = (`u64 프레임 시작 샘플` · `u64 첫 프레임 기준 바이트 위치` · `u32 블록 크기`).
  칸 k = 샘플 `k · floor(전체 샘플 / 400)`이 든 FLAC 프레임(나눗셈을 먼저 버리므로 뒤 칸일수록 조금 앞을 가리킨다). 라이브러리 1,083곡 중 1,081곡 바이트까지 일치(`djc lab pvb2-check`). 나머지 2곡은 시작 샘플은 같고 바이트 위치만 달라 분석 뒤 파일이 바뀐 것으로 본다.
- 막음: LAME이 아닌 VBR MP3(비트레이트 규칙 들쭉날쭉), 프레임이 중간에 끊긴 MP3·FLAC(STREAMINFO 전체 샘플과 프레임 합이 다름), ALAC.

**아트워크**(#4): rekordbox는 곡을 **분석할 때** 음원 내장 그림(ID3 APIC·iTunes covr·FLAC PICTURE)으로 파일 셋을 만든다. 자동 분석을 끄고 넣을 때는 만들지 않는다. XML로 들어온 곡(`Analysed` 41)에도 없었다.
- 실험(2026-09-26, rekordbox 7.2.18): 1200×900 JPEG 앞표지(APIC)가 든 MP3 "DJC 실험 아트"(라이브러리에 없던 아티스트·앨범)를 자동 분석을 끄고 넣고 종료했다. 다음 세션에서 자동 분석을 켜자 rekordbox가 이 곡을 분석했다. 넣기 전·넣은 직후·분석 뒤 스냅샷을 `djc lab db-diff`로 비교했다(넣기 전 스냅샷은 rekordbox 자동 백업과 같은 상태).
  - 넣을 때: `djmdArtist` → `djmdAlbum` → `djmdContent` 행만 생기고 변경 번호도 이 순서다(`localUpdateCount` +3). `ImagePath` 빈 값, 파일 행·아트워크 파일 없음, `djmdAlbum.ImagePath` NULL, `imageFile` 표 그대로(0행). 곡 행은 `djc lab track-add-repro`로 19칸 모두 같았다.
  - 분석할 때: `artwork.jpg` 파일 행이 먼저 번호를 받고(분석 결과를 쓰기 2초 전) → 오토게인 행 → 곡 행(`ImagePath`와 분석 칸) → 파일 행 .3EX → .2EX → .DAT → .EXT. 아트워크 행과 곡 행 사이 번호 일부는 비어 있어(같은 세션의 다른 곡 추가가 섞임) 곡 행이 이 사이에 번호를 몇 번 받았는지는 알 수 없다. `djmdAlbum.ImagePath`·`imageFile`은 그대로.
  - 이미 분석한 곡은 다시 뽑지 않는다: 아트워크를 넣기 전의 DJCrate로 분석까지 붙여 넣은 곡 중 음원에 그림이 있는 곡(3곡)은 그 뒤 rekordbox를 켜도(위 자동 분석 세션 포함) `ImagePath`가 빈 값이었다.
- 폴더는 곡 UUID로 정한다: `/PIONEER/Artwork/<UUID 앞 3자>/<나머지>/`(분석 폴더와 같은 규칙, 아트워크 있는 곡 전부 일치). `djmdContent.ImagePath` = 그 안의 `artwork.jpg`, 없으면 빈 값 `''`. `djmdAlbum.ImagePath`는 전부 NULL(건드리지 않는다).
- 파일 셋(라이브러리 조사: 스냅샷 사본과 share 읽기 전용, 아트워크 있는 곡 전부·파일 19,914개): `artwork.jpg`는 원본 크기 그대로, 긴 변이 800을 넘으면 800으로 줄인다(비율 유지, 짧은 변 반올림: 900×784 → 800×697, 3311×3001 → 800×725, 실험 곡 1200×900 → 800×600). `artwork_m.jpg` 240×240·`artwork_s.jpg` 80×80은 정사각에 맞게 키우거나 줄이고 남는 곳은 검은 여백으로 가운데 맞춘다(200×200 원본도 240으로 키움).
- 셋 다 원본이 JPEG여도 다시 인코딩한 기준선 JPEG다(PNG도 JPEG로): 머리는 SOI · APP0(JFIF 1.01, 비율 1:1, 썸네일 없음) · DQT 둘(libjpeg 품질 85 휘도·색차 표) · SOF0(Y 2x2, Cb·Cr 1x1) · DHT 넷(DC0·AC0·DC1·AC1, 최적화라 그림마다 다름) · SOS. EXIF·ICC 없음. 19,914개 전부 같은 머리.
- 파일 행(`contentFile`)은 `artwork.jpg` 하나만(`_m`·`_s`는 행 없음, 6,637행). 칸은 분석 파일 행과 같다(ID `<곡 UUID>_<경로, /는 %2F>`, MD5, 크기, `rb_local_path`, `rb_priority` 50). 실험 곡 행도 전 칸이 이 모양이다(`rb_insync_hash`·`rb_insync_local_usn`·`rb_temp_path`·`usn` NULL, 나머지 상태 칸 0, `UUID` 소문자 v4, `created_at` = `updated_at`).
- 빼면 파일 셋을 지우고 폴더는 남긴다(サラマンダー 복사본 삭제 실험).
- DJCrate(`TrackArtwork`·`ArtworkJPEG`): **분석까지 붙여 넣는 곡에만** 넣는다(`RekordboxTrackWriter.writesArtwork`, 위 실험으로 2026-09-26 열었다). 분석 없이 넣는 곡은 rekordbox처럼 넣지 않고, rekordbox에서 분석하면 생긴다고 확인 창에 알린다. 변경 번호는 위 "추가(분석 포함)" 순서에서 오토게인 행 앞이다(`RekordboxTrackArtworkTests`).
  같은 크기·여백·머리로 만들고 바이트는 다르다(허프만 표가 그림마다 다르고, 축소 방식·DCT가 다름). `djc lab artwork-check`로 라이브러리 곡의 음원 그림을 다시 만들어 비교하면(21곡) `artwork.jpg`는 머리 같음·화소 차이(0~255) 중앙 0.1·최대 1.1·크기 비 0.997~1.009로 거의 같고, `_m`·`_s`는 축소 필터 차이로 중앙 4.4·8.1(시험한 필터 중 CoreGraphics 고품질이 가장 가까움). 실험 곡은 머리 같음·화소 차이 0.1·2.5·4.9·크기 비 1.001·0.95·0.99.
- 확인하지 않은 것: 투명한 PNG(검은 바탕에 그림), EXIF 회전(무시), 그림이 여럿일 때 고르는 그림(AVFoundation이 주는 첫 그림), 분석 말고 다른 때(곡 선택·덱에 올리기·태그 다시 읽기 등) 아트워크를 뽑는지. 라이브러리의 분석하지 않은 곡(`Analysed` 0)에도 아트워크가 있는데, 넣을 때는 뽑지 않으므로 그런 다른 길이나 옛 버전에서 온 것으로 보인다.
- 분석 붙이기(`RekordboxWriter+Analysis`, 기존 분석 전 곡)는 아직 아트워크를 넣지 않는다. 위 실험의 "분석할 때"가 바로 그 경우라 rekordbox는 넣는다(따로 열 일).
- 라이브러리에는 음원에 그림이 없는데 `ImagePath`가 있는 m4a가 있다(파일에 `covr`가 없음). rekordbox에서 직접 붙였거나 넣은 뒤 태그가 바뀐 곡으로 보고, DJCrate는 음원에 그림이 없으면 아트워크를 만들지 않는다.

**삭제**: 삭제 표시가 아니라 행을 실제로 지운다.
- 곡 행, 큐(`djmdCue`·`contentCue`), 파일 행, 오토게인 행, 재생 목록·재생 이력 항목. 같은 이력의 뒤 순번을 하나씩 당기고 그 행들은 한 변경 번호로 몰아 받는다(재생 목록도 같다고 보고 당긴다: 추정).
- 그 곡만 쓰던 아티스트·앨범 행도 지운다. 분석 폴더는 통째로, 아트워크는 파일만 지운다(폴더는 남김).
- MyTag·핫큐 뱅크·샘플러·관련 곡·신청곡·검열 구간·클라우드 내보내기에 걸린 곡은 아직 지우지 않는다.

## 분석 붙이기 (분석 전 곡, `RekordboxWriter+Analysis`, #6)

라이브러리에 이미 있는데 분석 파일이 없는 곡에, 반영할 때 그 곡의 그리드 초안으로 분석 파일을 만들어 붙인다. 곡 넣기(분석 포함) 레시피(`RekordboxTrackWriter.prepare`·`fileRow`·`mixerRow`)를 쓰고, 쓰기는 `RekordboxWriter.write`의 안전 절차(사전 확인 → 백업 → 한 트랜잭션 → 다시 읽어 검증 → 무결성 검사 → 실패 시 복원)를 따른다.

**분석 전 곡은 두 가지다**(2026-09-26 라이브러리 조사, 읽기 전용):
- 분석 파일 없음: `AnalysisDataPath` 빈 값. 자동 분석을 끄고 넣은 곡(`Analysed` 0, `ContentLink` 14)과 XML로 들어온 곡(`Analysed` 41, `ContentLink` 14, BPM·비트레이트·샘플레이트는 XML 값, `AnalysisUpdated`·`TrackInfoUpdated` NULL). 파일 행·오토게인 행이 없다. → 분석을 붙인다.
- 반쪽 분석: `.DAT`(PQTZ 0박, PWAV·PWV2 전부 0)와 `.3EX`, 그 파일 행(`.DAT`·`.3EX`, 아트워크), 오토게인 행은 있고 `.EXT`·`.2EX`가 없다(`Analysed` 105, BPM 0이거나 태그 BPM, `AnalysisUpdated`·`TrackInfoUpdated` "1"). rekordbox 분석이 실패한 흔적으로 보인다. → 막는다(아래). 그리드가 든 채 `.EXT`만 없는 곡은 라이브러리에 없었다.

**실험**(2026-09-26, rekordbox 7.2.18, 자동 분석 끔, '트랙 분석' 보통 모드·BPM/그리드·키만, 프레이즈·보컬 끔): XML로 들어온 분석 전 곡 The Asterisk War (edit)(WAV)와 반쪽 곡 ヴァンパイア(M4A). 전후 스냅샷을 `djc lab db-diff`로 비교하고, 실험 전 사본에 같은 곡을 `djc lab analysis-attach-test --grid-from <rekordbox .DAT>`로 써서 칸마다 맞췄다.

**rekordbox가 분석 전 곡을 분석하면**(The Asterisk War (edit)):
- `djmdContent`: `AnalysisDataPath`(곡 UUID 폴더), `Analysed` 41→105, `ContentLink` 14→0x2C060E, `AnalysisUpdated` NULL→'2', `TrackInfoUpdated` NULL→'1'(글자), 변경 번호, `updated_at`. BPM·Length·BitRate·BitDepth·SampleRate는 XML 값이 분석 값과 같아 그대로였다(분석 전 추가 곡은 채운다: 2026-09-26 O-Ku-Ri-Mo-No Sunday! 241→240초 버림). 키 분석을 켰는데도 `KeyID`는 0 그대로였다(#5 참고).
- `contentFile` 행 4개(.3EX·.2EX·.DAT·.EXT, 곡 넣기와 같은 칸), `djmdMixerParam` 행 1개(피크 1.0).
- 변경 번호: 오토게인 행 → .3EX 행 → 곡 행 → .2EX → .DAT → .EXT. rekordbox는 두 번에 나눠 쓴다(오토게인·.3EX·.DAT 행을 먼저 만들고 몇 분 뒤 곡 행·나머지 파일 행, .DAT 행은 그때 다시 고침). 파일 행 순서 .2EX → .DAT → .EXT는 O-Ku-Ri-Mo-No Sunday!·ヴァンパイア에서도 같았다.

**DJCrate가 쓰는 것**(골든 테스트 `RekordboxAnalysisAttachTests`: 같은 음원·그리드·음량이면 곡 넣기 결과와 칸·바이트까지 같고, 다른 것은 위 실험의 카운터·순서뿐):
- 분석 파일 `.DAT`·`.EXT`·`.2EX`를 곡 UUID 폴더(`/PIONEER/USBANLZ/<UUID 앞 3자>/<나머지>`)에 새로 만든다. PPTH의 파일 이름은 `FileNameL`.
- `djmdContent`: BPM(첫 구간 ×100)·Length(AVFoundation 길이 버림)·BitRate·BitDepth·SampleRate·AnalysisDataPath·`Analysed` 105·`ContentLink` 0x2C060E·`AnalysisUpdated` '2'·`TrackInfoUpdated` '1', 상태 256→257, 변경 번호, `updated_at`. `KeyID`는 건드리지 않는다.
- `contentFile` 행 3개와 `djmdMixerParam` 행(오토게인, −10 LUFS 목표). 변경 번호는 오토게인 행 → 곡 행 → .2EX → .DAT → .EXT(.3EX는 만들지 못한다).
- 같은 쓰기의 큐·게인 초안은 분석을 붙인 뒤에 쓴다(분석한 곡을 고치는 순서).
- 파일은 DB를 커밋하고 다시 읽어 확인한 뒤 쓴다. 파일 쓰기가 실패하면 만든 파일·빈 폴더를 지우고 DB를 백업으로 되돌린다.
- 되돌리기: 백업 보고서(`report.json`)의 `createdFiles`로 만든 파일과 빈 분석 폴더를 지우고, 백업에 둔 그리드 초안을 살린다.

**사본 재현 결과**(실험 전 사본, rekordbox 그리드를 PQT2 소수까지 가져와서): 곡 행은 바뀐 칸·값이 rekordbox와 같다(변경 번호 값·시각 말고). 파일 행 3개는 ID까지 같고 나머지 칸도 같다. `.DAT`는 머리·PPTH·PVBR·PCOB가 바이트까지 같고, PQTZ는 227박 중 9박만 1ms 다르다(rekordbox 박 간격이 419.49~419.60ms로 흔들려 소수가 ms 경계에 붙은 박). `.2EX`·`.DAT` 크기는 같고 `.EXT`는 PQT2 빈 형태만큼(박당 2바이트) 작다. 파형 태그는 곡 넣기와 같은 근사. 오토게인은 0.09dB 차이(음량 측정 차, 위 ±0.25dB 안).

**막는 것**:
- 반쪽 분석 곡(.DAT만): "rekordbox에서 트랙 분석을 다시 한 뒤 쓰세요". rekordbox가 다시 분석하면(ヴァンパイア) 곡 행은 BPM·`AnalysisUpdated`+1·`TrackInfoUpdated`+1·변경 번호만 바뀌고(`ContentLink`는 그대로), `.DAT`를 새로 써서 그 파일 행 해시·크기를 고치고, `.3EX` 해시를 고치고, `.2EX`·`.EXT` 파일 행을 넣는다(곡 행 → .3EX → .2EX → .DAT → .EXT). 오토게인 행은 그대로였다. 이 경로는 아직 쓰지 않는다.
- 카운터(`AnalysisUpdated`·`TrackInfoUpdated`)가 이미 있는 분석 전 곡(rekordbox에서 곡 정보를 고친 곡): 분석하면 얼마나 느는지 확인하지 않았다.
- 오토게인 행·USBANLZ 파일 기록·분석 폴더 파일이 이미 있는 곡, 음원 파일이 없는 곡, 음원 길이를 재지 못한 곡, base가 있는 초안(초안을 만든 뒤 rekordbox 쪽이 바뀜), 곡 넣기에서 막는 형식(ALAC·LAME이 아닌 VBR MP3·프레임이 끊긴 MP3·FLAC).

`RekordboxWriter.attachesAnalysis`로 경로 전체를 닫을 수 있다(규칙이 어긋나는 것이 드러나면 닫는다).

**rekordbox가 음원 파일도 고친다**: 태그를 고치면 파일 태그를 다시 쓰고(m4a 확인), 분석하면 키 태그(TKEY 등)를 써 넣는다(파일 크기가 커짐). 자동 분석을 켜면 라이브러리의 분석 안 된 곡까지 한꺼번에 분석한다.

## ALAC 분석 파일 조사 (#8, 2026-09-26)

**결론: ALAC 기준 표본을 확인하지 못해 규칙을 확정하지 못했다. 분석 붙이기 차단을 유지한다.** 아래는 기존 스냅샷을 읽은 결과이며, rekordbox에서 새로 분석한 전후 비교가 아니다.

- **[확인]** 조사 당시 최신 스냅샷(2026-09-26 10:17:23 UTC)의 삭제되지 않은 곡 중 `FileType IN (3, 4)` 또는 확장자가 `.m4a`인 후보를 전부 조회했다. 음원이 있는 후보는 `AudioFileOpenURL(.readPermission)`로 열어 `kAudioFilePropertyDataFormat`을 읽고, `ffprobe -select_streams a:0 -show_entries stream=codec_name`으로 교차 확인했다. 파일은 읽기만 했고 식별값·경로·곡 수는 기록하지 않았다.
- **[확인]** AudioToolbox에서 확인한 형식은 `aac `·`paac`, ffprobe에서는 `aac`였다. `alac`는 확인되지 않았다. 음원이 없는 후보도 있으므로 라이브러리에 ALAC이 없다는 결론은 낼 수 없다.
- **[확인]** `.m4a` 확장자나 `djmdContent.BitDepth`만으로 ALAC을 고를 수 없다. `BitDepth = 32`인 후보도 실제 코덱을 읽으면 ALAC이 아니었다.
- **미확인**: ALAC으로 확인된 음원과 연결된 `.DAT`·`.EXT` 기준 표본을 얻지 못했다. 따라서 태그 순서·`PVBR`·`PVB2` 유무/내용, `BitRate`·`BitDepth`·`SampleRate`, 큐의 MPEG·SeekInfo 칸은 모두 ALAC 규칙으로 확정할 수 없다. 대조 대상이 없으므로 "전수 대조 어긋남 0"으로 세지 않는다. `AudioFacts`·`TrackAnalysisFiles`와 쓰기 조건은 바꾸지 않았다.

**필요한 rekordbox 실험**:

1. 개인 음원 대신 합성 ALAC M4A(16/24비트, 44.1/48kHz, 스테레오)를 준비하고, 실제 코덱이 `alac`인지 먼저 확인한다. 자동 분석을 끈 rekordbox 7.2.18에 넣은 뒤 종료해 분석 전 스냅샷을 보관한다.
2. 사용자가 그 합성 곡만 "트랙 분석"(보통 모드, BPM/그리드·키, 프레이즈·보컬 끔)하고 종료한다. 분석 뒤 스냅샷과 실제 복사한 share에서 `.DAT`·`.EXT` 태그, 곡 행의 음원 칸·분석 카운터·파일 행을 비교한다. 탐색 칸은 별도 단계로 메모리 큐·핫큐·루프를 넣은 전후 스냅샷에서 확인한다.
3. 규칙이 보이면 합성 테스트를 먼저 실패시킨 뒤 구현하고, 읽기 전용 `djc lab` 전수 대조에서 코덱 확인 실패·음원/분석 파일 누락을 일치와 구분한다. 사본 재현으로 칸 단위 일치를 확인하기 전에는 쓰기 경로를 열지 않는다.

## 막아 둔 것 (규칙 미확인)

- **템포 구간이 여러 개인 곡의 BPM 변경**: 구간 이동은 되지만 BPM 변경은 막는다.
- **분석을 붙인 곡 추가 중 ALAC·LAME이 아닌 VBR MP3**: 분석 파일 규칙(ALAC)·비트레이트 칸 규칙(비LAME VBR)을 못 찾았다. 분석 전 추가만 한다. 분석 붙이기도 같다.
- **반쪽 분석 곡(.DAT만 있고 .EXT 없음)의 그리드·분석 붙이기**: rekordbox가 다시 분석한 모양은 한 곡 보았지만(위 "분석 붙이기") 사본 재현으로 확인하지 않았다.
- **카운터가 이미 있는 분석 전 곡에 분석 붙이기**: `AnalysisUpdated`·`TrackInfoUpdated`가 NULL인 곡만 확인했다.

## 새 쓰기 경로를 여는 방법

1. 사용자에게 rekordbox에서 그 편집을 직접 해 달라고 한다(곡 이름 받기, 끝나면 rekordbox 종료).
2. 편집 전 스냅샷과 새 스냅샷(`djc snapshot --force`)을 `djc lab sql <사본> "…"`·`djc lab db-diff`로 비교: 바뀐 테이블·칸·usn 순서.
3. 실험 전 사본에 DJCrate로 같은 편집을 써서 칸마다 비교(예: `djc lab loop-repro --old … --new … --ids … --work <폴더>`).
4. 일치하면 `Tests/RekordboxKitTests`에 골든 테스트를 먼저 쓰고, 막아 둔 조건을 풀고, 이 문서에 규칙을 적는다.
