# AGENTS.md — anicue

rekordbox 7용 애니송 DJ 라이브러리 관리 macOS 앱(1인용). 사람·Claude Code·Codex 등 모든 에이전트가 따르는 정본이다. 기능 소개는 `README.md`, rekordbox 쓰기 규칙은 `docs/rekordbox-internals.md`, 구조·설계 결정은 `docs/architecture.md`.

- IMPORTANT: 사용자에게 하는 말·보고·질문은 항상 한국어로 한다.

## 가장 중요한 규칙: rekordbox 라이브러리를 절대 깨뜨리지 않는다

- IMPORTANT: rekordbox 또는 rekordboxAgent가 켜져 있으면 rekordbox 라이브러리(`master.db`, `share/PIONEER/USBANLZ`)에 **절대 쓰지 않는다**. 쓰기는 `RekordboxWriter.write` 한 곳으로만 한다(전체 백업 → 한 트랜잭션 → 다시 읽어 검증 → 무결성 검사 → 실패 시 복원).
- 라이브 DB·음원은 읽기 전용이다. 읽기는 스냅샷 사본(`LibrarySnapshot`)에서 한다.
- 시험·실험 쓰기는 **사본에만** 한다: `ANICUE_REKORDBOX_DIR=<사본 폴더>`, `ANICUE_HOME=<임시 폴더>`. 사본의 `share/PIONEER/USBANLZ`는 심볼릭 링크가 아니라 실제 복사본이어야 한다.
- 규칙을 확인하지 않은 쓰기(VBR MP3 큐, 템포 구간 여러 개인 곡의 BPM 변경, DB에 새 곡 추가)는 막아 둔다. 새 쓰기 경로는 rekordbox 실험 → 사본 재현 → 칸 단위 일치를 확인한 뒤에만 연다(`docs/rekordbox-internals.md` 끝).
- rekordbox DB 사본(`*.db`, `-wal`, `-shm`, `snapshots/`)에는 클라우드 토큰이 들어 있다. 커밋·출력·로그 금지. `agentRegistry`의 인증값은 읽지도 옮기지도 않는다.

## 명령

```bash
swift build                          # 전체(코어·CLI·앱) 디버그 빌드
swift test                           # 단위 테스트(Swift Testing, AnicueCoreTests)
swift build -c release --product AnicueApp
scripts/build-app.sh                 # dist/anicue.app 만들기(릴리스·번들·로컬 서명)
scripts/build-app.sh --install       # 만들고 /Applications에 설치
.build/debug/anicue                  # CLI 도움말(명령 목록)
.build/debug/anicue snapshot [--force]            # 라이브 DB 읽기용 사본 뜨기
.build/debug/anicue sql <사본.db> "SELECT …"       # 사본에 읽기 전용 질의
.build/debug/anicue cue-write --db <사본.db> [--dry-run]   # 초안을 사본에 써 보기
```

- 앱 개발용 실행 인자: `--db <스냅샷>`(그 사본을 연다), `--select <ContentID>`(곡을 골라 둔다).
- 환경 변수: `ANICUE_HOME`(초안·백업 폴더를 바꿈), `ANICUE_REKORDBOX_DIR`(rekordbox 폴더 사본), `ANICUE_DB`(열 스냅샷), `ANICUE_IDLE_SECONDS`(재생 멈춘 뒤 엔진 끄기까지).

## 검증 (작업이 끝났다고 말하기 전에)

- `swift build`와 `swift test`가 통과해야 한다. 코어 로직을 바꾸면 `Tests/AnicueCoreTests`에 테스트를 더한다.
- 소리·UI·rekordbox 쓰기는 앱 자가 테스트로 확인한다. 초안이 사용자 것과 섞이지 않게 항상 `ANICUE_HOME=<임시 폴더>`를 준다:

| 인자 | 확인하는 것 | 추가 조건 |
|---|---|---|
| `--write-selftest` | 반영(미리 보기·쓰기·조용한 다시 읽기·되돌리기) 전 과정 | `ANICUE_REKORDBOX_DIR` 사본 필수 |
| `--loop-selftest` | 활성 루프·즉석 루프·½·핫큐 저장·나가기 | `--select`로 활성 루프 있는 곡 |
| `--loop-audio-selftest` | 루프 이음새가 샘플 단위로 맞는지(램프 WAV) | — |
| `--carry-selftest` | 그리드 이동·BPM 변경 때 핫큐 따라가기 | `--select`로 핫큐 있는 곡 |
| `--switch-selftest` | 곡 전환·일시정지 뒤 소리 | — |
| `--scroll-perf` | 재생 중 목록 스크롤 때 프레임 간격(릴리스로) | `--perf-hide=zoom,label,…`로 A/B |

예: `ANICUE_HOME=$(mktemp -d) .build/debug/AnicueApp --db <스냅샷> --select 32395449 --loop-selftest 2>&1 | grep "루프 시험"`

- 결과는 추측하지 말고 명령 출력(통과/실패 줄, 수치)을 보여 준다.
- 새 앱 인자는 `--이름=값` 한 덩어리로 만든다. 값을 따로 쓴 `--perf-hide zoom`은 AppKit이 값을 열 파일로 보고 앱이 멈췄다.

## 구조

- `Sources/AnicueCore/` — UI 없는 로직(테스트 대상).
  - `Rekordbox/`: DB·ANLZ 읽기·쓰기
  - `Analysis/`: 파형·그리드 추정·조성·음량·섹션
  - `Cue/`: 큐·그리드·게인 초안
  - `Comment/`: 코멘트 규칙 파서
  - `Export/`: rekordbox XML
  - `Staging/`: 새로 추가한 곡
  - `Tags/`: 태그 초안·TSV
- `Sources/AnicueApp/` — SwiftUI+AppKit 앱.
  - `LibraryStore*`: 목록·필터·반영
  - `DeckModel`·`DeckAudio`: 재생·큐·루프·그리드 편집
  - `WaveformViews`·`DeckView`: 덱 화면
  - `TrackTable`: NSTableView 목록
  - `KeyRouter`: 단축키
  - `DevSelfTests`: 자가 테스트
- `Sources/anicue/main.swift` — 개발·실험용 CLI.
- 사용자 데이터: `~/Library/Application Support/anicue/`
  - 초안: `cue-drafts/`, `grid-drafts/`, `gain-drafts.json`, `tag-drafts/`
  - 그 밖: `staged.json`, `snapshots/`, `rekordbox-backups/`, 캐시(`analysis/`, `waveforms/`, `loudness.json`)

## 핵심 설계 결정 (코드만 봐서는 모르는 것)

- 편집은 모두 **초안**(`CueDraft`·`GridDraft`·게인 초안)으로 쌓고, 반영 때만 rekordbox에 쓴다. 초안은 만들 때의 rekordbox 상태(`base`)를 들고 있어, 그 뒤 rekordbox에서 바뀐 곡은 쓰지 않는다.
- 덱·초안의 시각은 모두 **rekordbox 시간축**(음원 시각 + 인코더 지연, `RekordboxTimeline.predictedOffset`)이다. 파형만 음원 시간축이라 `timelineOffset`만큼 당겨 그린다.
- 오디오:
  - `AVAudioEngine.pause()`를 쓰지 않는다. 멈출 땐 `stop()`. pause 뒤 다시 켜면 시작 시각이 밀려 소리가 늦고 무음이 쌓인다.
  - 루프는 재생 노드에 버퍼를 예약해 샘플 단위로 잇는다(`DeckAudio.setLoop`). 예약은 렌더 블록보다 앞서야 하고, 되풀이 버퍼는 바퀴 경계에서만 끊는다.
- 화면: 재생 중 매 프레임 바뀌는 관찰 값은 큰 뷰가 읽지 않게 한다. 글자·전체 파형 재생선은 `displayTime`(15Hz), 레벨 미터는 재생 틱(`meterFrame`)으로 갱신한다.
- 그리드 쓰기는 파형 파일(`.EXT`)이 있는 곡만 한다(rekordbox 분석 전 곡은 막음).
- 새 곡은 rekordbox XML(Import To Collection)로 넘긴다. 이미 컬렉션에 있는 경로는 막는다(기존 큐 덮어쓰기 방지).

## 코드 스타일

- UI 문구·주석·커밋 메시지는 한국어, 식별자는 영어.
- 주석은 "왜"를 짧게 한국어로. 둘레 코드의 주석 밀도와 말투에 맞춘다.
- 사용자에게 보이는 막힘·오류 이유는 무엇을 하면 되는지까지 한국어 한 문장으로 쓴다(예: "rekordbox에서 트랙 분석을 먼저 한 뒤 쓰세요").
- Swift 6 엄격 동시성. 오디오 탭·렌더 콜백은 메인 액터 밖(`nonisolated static`)에서 만든다. 메인 액터 격리를 물려받으면 오디오 스레드에서 죽는다.

## 저장소 규칙

- 브랜치:
  - `main`: 릴리스
  - `dev`: 통합
  - 작업 브랜치: `feat/…`, `fix/…`, `chore/…`, `hotfix/…`, `release/vX.Y.Z`
  - 작업 브랜치는 `dev`에서 따고, `git merge --no-ff`로 dev에 합친다("Merge branch 'feat/…' into dev").
- 커밋 제목: `타입: 한국어 설명`(마침표 없음). 타입 = feat, fix, docs, style, design, test, refactor, build, ci, perf, chore, rename, remove. 자세한 내용은 본문에 불릿으로.
- 커밋·푸시는 요청받았을 때만 한다.
- 빌드해서 앱을 바꿀 때: anicue가 꺼져 있으면 `scripts/build-app.sh --install`로 설치한다. **켜져 있으면 끄기 전에 사용자에게 묻는다.**

## rekordbox 실험이 필요할 때

사용자에게 rekordbox에서 그 편집을 직접 해 달라고 부탁하고(곡 이름을 받고, 끝나면 rekordbox 종료), 전후 스냅샷을 비교한다. 방법은 `docs/rekordbox-internals.md`의 "새 쓰기 경로를 여는 방법".
