# rekordbox 7 내부 형식 — anicue가 알아낸 쓰기 규칙

rekordbox 7.2.18에서 사용자가 직접 편집한 결과를 스냅샷끼리 diff해서 뽑은 규칙이다. 각 규칙은 "실험 전 사본에 anicue로 같은 편집을 쓰고, rekordbox가 쓴 결과와 칸마다 비교"해서 확인했다. 확인하지 못한 규칙은 코드에서 막아 두었다(아래 "막아 둔 것").

코드: `Sources/RekordboxKit/` — `RekordboxWriter`(DB, 역할별 `+Cues`·`+Grid`·`+Gain`·`+Verify`·`+Backup`), `RekordboxGridWriter`(ANLZ), `RekordboxCompatibility`(쓰기 전 버전·구조 확인), `CueJSON`, `AnlzFile`, `SeekInfo`, `CipherDatabase`.

## 파일과 열기

- 라이브러리: `~/Library/Pioneer/rekordbox/master.db` (SQLCipher 4). 키는 pyrekordbox와 같은 방식으로 푼다(`RekordboxKey.derive()`).
- 분석 파일: `~/Library/Pioneer/rekordbox/share/PIONEER/USBANLZ/<3자리>/<uuid 나머지>/ANLZ0000.{DAT,EXT,2EX,3EX}`. 경로는 `djmdContent.AnalysisDataPath`(`.DAT` 경로).
- 삭제 행이 절반쯤 있다(`rb_local_deleted=1`). 집계·쓰기는 항상 삭제되지 않은 행만.
- `agentRegistry`에는 클라우드 인증값이 들어 있다. 읽거나 출력하지 않는다(`anicue lab sql`은 이 테이블 질의를 막는다). 예외: 쓰기 모듈이 `localUpdateCount`를 읽고 쓰고, `lastUpdateCount`의 정수 칸만 읽는다.

## 쓰기 전 확인 (`RekordboxCompatibility`)

쓰기 규칙은 rekordbox 7.2.18에서 확인했다. rekordbox가 업데이트로 DB 구조를 바꾸면 규칙이 맞지 않을 수 있어서, 쓰기 전에 다음을 보고 하나라도 다르면 **백업도 뜨지 않고** 막는다.

- 앱 버전: `/Applications/rekordbox N/rekordbox.app`의 `CFBundleShortVersionString` 주.부가 `7.2`(못 찾으면 아래 DB 검사에 맡김). 라이브 DB에만 적용.
- 새 행을 넣는 표(`djmdCue` 29칸, `contentCue` 13칸)는 칸 이름이 정확히 같아야 한다. 칸이 늘면 rekordbox가 기대하는 값을 빠뜨리게 된다.
- 고치거나 읽는 칸(`djmdContent`·`contentFile`·`djmdMixerParam`·`agentRegistry`·`djmdProperty`)은 모두 있어야 한다.
- `djmdProperty.DBVersion` = `6000`.
- `localUpdateCount` ≥ `lastUpdateCount`(클라우드 동기화가 본 가장 큰 번호). 로컬 번호가 더 작으면 동기화 때 변경이 되돌려졌다는 사례가 있다(2026-09-26 조사). 2026-09-26 실제 라이브러리: 로컬 1,002,950 · 클라우드 372,628.

`anicue compat`으로 읽기 전용 확인을 할 수 있다. 새 rekordbox 버전을 허용하려면 "새 쓰기 경로를 여는 방법"처럼 실험으로 큐·그리드·게인 쓰기를 다시 확인한 뒤 `verifiedAppVersions`를 넓힌다.

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
- 활성 루프는 곡당 하나(라이브러리에 둘 이상인 곡 없음). rekordbox는 활성 켜기를 행 제자리 UPDATE로 하고 `CueUpdated`를 안 올리지만, anicue는 지우고 새로 넣는다(결과 상태는 같음).

### 파일 형식별 탐색 위치

- MP3 CBR·M4A·WAV: `InMpegFrame`·`InMpegAbs` 0, SeekInfo NULL.
- FLAC: `InPointSeekInfo` = `"<큐 샘플이 든 FLAC 프레임 시작 샘플>,<그 프레임 바이트 위치 − 첫 오디오 프레임 위치>,<블록 크기>"`. 루프가 아니면 `OutPointSeekInfo` = `"0,0,0"`, 루프면 끝 지점을 같은 식으로. 기존 큐 1,818개·루프 끝 전부와 일치.
- VBR MP3: 막아 둠(아래).

## 비트그리드 (ANLZ)

- `.DAT`의 `PQTZ`: 박마다 `박 번호(u16 1~4) · BPM×100(u16) · 시각 ms(u32)`. 시각은 정밀 시각을 **내림**, 곡 앞 −1ms 안의 박은 0.
- `.EXT`의 `PQT2`: 머리에 첫 박·마지막 박·박 수·정체 모를 u32, 본문은 박마다 (ms 아래 소수 × 1024). rekordbox가 그리드를 손으로 고치면 PQT2를 빈 형태(머리 0·본문 없음)로 바꾼다 → anicue도 그렇게 쓴다.
- 이동만 하면 DB는 안 바뀐다(`contentFile` 해시도 그대로).
- BPM을 바꾸면:
  - `.DAT`의 `contentFile` 행: `Hash`(새 파일 MD5), `Size`, `rb_data_status`, `rb_local_usn`, `updated_at`.
  - `djmdContent`: `BPM`(×100), `AnalysisUpdated`+1·`TrackInfoUpdated`+1(글자형), 상태, usn.
  - 소수(PQT2)가 없으면 첫 박을 ms + 0.5로 보고 다시 계산한다(바이트까지 재현).
- 다른 태그는 바이트 그대로 둔다(`AnlzFile`이 태그 단위로 읽고 PMAI 전체 길이만 다시 적는다).
- **파형 파일(.EXT)이 없는 곡은 rekordbox 분석 전 곡이다**(BPM 0, PQTZ 0박). 그리드만 쓰면 파형 없는 채로 남으므로 막는다(2026-09-26 サラマンダー).

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
3. `BEGIN IMMEDIATE` 한 트랜잭션에서 쓰고, 같은 연결로 다시 읽어 초안과 칸마다 비교.
4. 커밋 뒤 다시 열어 한 번 더 검증 + `PRAGMA quick_check` + `cipher_integrity_check`.
5. 어느 단계든 실패하면 백업으로 되돌린다. 초안을 만든 뒤 rekordbox에서 그 곡이 바뀌었으면(base 불일치) 그 곡은 쓰지 않는다.

## 막아 둔 것 (규칙 미확인)

- **VBR MP3 큐**: rekordbox가 큐마다 `InMpegFrame` = InFrame/2, `InMpegAbs` = 큐보다 7~9프레임 앞 MPEG 프레임의 바이트 위치(첫 프레임 기준)를 적는다. 곡·큐마다 달라 규칙을 못 찾았다(Xing TOC 보간 가설 9.5% 일치).
- **템포 구간이 여러 개인 곡의 BPM 변경**: 구간 이동은 되지만 BPM 변경은 막는다.
- **새 곡 추가**: DB에 곡 행만 넣으면 분석 파일(파형)이 없어 불완전하다. 지금은 rekordbox XML(Import To Collection)로 넘긴다.

## 새 쓰기 경로를 여는 방법

1. 사용자에게 rekordbox에서 그 편집을 직접 해 달라고 한다(곡 이름 받기, 끝나면 rekordbox 종료).
2. 편집 전 스냅샷과 새 스냅샷(`anicue snapshot --force`)을 `anicue lab sql <사본> "…"`·`anicue lab db-diff`로 비교: 바뀐 테이블·칸·usn 순서.
3. 실험 전 사본에 anicue로 같은 편집을 써서 칸마다 비교(예: `anicue lab loop-repro --old … --new … --ids … --work <폴더>`).
4. 일치하면 `Tests/RekordboxKitTests`에 골든 테스트를 먼저 쓰고, 막아 둔 조건을 풀고, 이 문서에 규칙을 적는다.
