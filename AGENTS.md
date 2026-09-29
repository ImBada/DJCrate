# AGENTS.md — DJCrate

rekordbox 7용 DJ 라이브러리 관리 macOS 앱 DJCrate(약칭 DJC, CLI `djc`, 1인용, 옛 이름 anicue). 사람·Claude Code·Codex 등 모든 에이전트가 따르는 정본이다. 기능 소개는 `README.md`, rekordbox 쓰기 규칙은 `docs/rekordbox-internals.md`, 구조·설계 결정은 `docs/architecture.md`, 이슈 관리 규칙은 `docs/issues.md`.

- IMPORTANT: 사용자에게 하는 말·보고·질문은 항상 한국어로 한다.

## 가장 중요한 규칙: rekordbox 라이브러리를 절대 깨뜨리지 않는다

- IMPORTANT: rekordbox 또는 rekordboxAgent가 켜져 있으면 rekordbox 라이브러리(`master.db`, `share/PIONEER/USBANLZ`)에 **절대 쓰지 않는다**. 쓰기는 `RekordboxWriter.write` 한 곳으로만 한다(사전 확인 → 전체 백업 → 한 트랜잭션 → 다시 읽어 검증 → 무결성 검사 → 실패 시 복원).
- 사전 확인(`RekordboxCompatibility`, `RekordboxWriteGuard`): rekordbox 7.2.x만, DB 구조(`djmdCue`·`contentCue` 칸이 정확히 같고 고치는 칸이 있음)·`DBVersion` 6000, 로컬 변경 카운터 ≥ 클라우드 동기화 카운터. 막힐 조건은 백업을 뜨기 전에 본다. rekordbox가 업데이트되면 `djc compat`으로 먼저 확인하고, 실험으로 규칙을 다시 확인하기 전에는 허용 목록을 넓히지 않는다.
- 라이브 DB·음원은 읽기 전용이다. 읽기는 스냅샷 사본(`LibrarySnapshot`)에서 한다.
- 시험·실험 쓰기는 **사본에만** 한다: `DJC_REKORDBOX_DIR=<사본 폴더>`, `DJC_HOME=<임시 폴더>`. 사본의 `share/PIONEER/USBANLZ`는 심볼릭 링크가 아니라 실제 복사본이어야 한다.
- 규칙을 확인하지 않은 쓰기(템포 구간 여러 개인 곡의 BPM 변경, 미확인 ALAC 형식, 44.1kHz가 아닌 ffmpeg VBR·그 밖의 비LAME VBR 분석 붙이기)는 막아 둔다. 새 쓰기 경로는 rekordbox 실험 → 사본 재현 → 칸 단위 일치를 확인한 뒤에만 연다(`docs/rekordbox-internals.md` 끝).
- rekordbox DB 사본(`*.db`, `-wal`, `-shm`, `snapshots/`)에는 클라우드 토큰이 들어 있다. 커밋·출력·로그 금지. `agentRegistry`의 인증값은 읽지도 옮기지도 않는다.
- rekordbox 규칙은 rekordbox 화면에서 편집한 결과 파일을 비교해서만 알아낸다. rekordbox 실행 파일(본체·rb_http_server 등)은 strings·디스어셈블을 포함해 분석하지 않는다.
- 라이선스가 없는 외부 코드·문서는 쓰지 않는다. 외부 코드를 옮기면 라이선스를 확인하고 THIRD_PARTY_NOTICES.md에 더한다.
- 내보내는 파일(USB 등)은 칸 단위로 만든다. rekordbox가 만든 파일의 페이지·표 바이트를 통째로 넣지 않는다.
- USB 쓰기는 `UsbWriter.write` 한 곳으로만 한다. rekordbox·rekordboxAgent가 켜져 있으면 USB에도 쓰지 않는다.
- USB의 DB(`exportLibrary.db`·`export.pdb`·`exportExt.pdb`)는 Mac 사본에서만 연다. USB 위에서 SQLite를 열지 않는다.
- 실물 USB 쓰기는 코드에서 닫혀 있다(`UsbPhysicalWriteGate.buildEnabled`). 시험 쓰기는 `djc lab usb-image`로 만든 디스크 이미지에만 한다. 이미지·lab 출력은 임시 폴더 아래만(`UsbScratchPath`).
- `PIONEER/extracted`·`PIONEER/CDP`·`djprofile.nxs`는 열거·읽기·복사하지 않는다.

## 명령

```bash
scripts/check.sh                     # 커밋 전: 빌드(디버그·릴리스 앱) + 번역 누락 + 테스트 + 커버리지 목표(쓰기 80%, 코어 60%)
swift scripts/i18n.swift sync        # 코드의 화면 문구로 String Catalog 맞추기(새 문구 더하기·안 쓰는 문구 빼기). 뒤에 en·ja 번역을 채운다
swift build                          # 전체 디버그 빌드
swift test                           # 단위 테스트(Swift Testing, 테스트 타깃 4개)
swift test --filter WriteGuardTests  # 한 묶음만
scripts/coverage.sh [경로 정규식]     # 파일별 줄 커버리지
scripts/build-app.sh [--install]     # dist/DJCrate.app(릴리스·번들·로컬 서명), --install이면 /Applications에
.build/debug/djc                  # CLI 명령 목록
.build/debug/djc compat           # rekordbox 버전·DB 구조·카운터가 쓰기를 확인한 모양인지(읽기 전용)
.build/debug/djc snapshot [--force]                    # 라이브 DB 읽기용 사본 뜨기
.build/debug/djc cue-write --db <사본.db> [--dry-run]   # 초안을 사본에 써 보기
.build/debug/djc track-add --db <사본.db> --share <폴더> --analyze <음원…>   # 곡 넣기(분석까지), 사본에만
.build/debug/djc track-delete --db <사본.db> --share <폴더> <ContentID…>      # 곡 빼기, 사본에만
.build/debug/djc playlist-write --db <사본.db> [--dry-run] <편집.json>        # 재생 목록 편집(JSON), 사본에만
.build/debug/djc lab                                   # 실험 명령 목록(sql·loop-repro·seekinfo-check …)
.build/debug/djc lab sql <사본.db> "SELECT …"           # 사본에 읽기 전용 질의
.build/debug/djc usb-export --volume <마운트> --db <사본.db> (--playlist <ID>… | --tracks <ID,…>) [--dry-run] [--snapshot-time <ISO 8601>]   # 빈 USB에 두 형식으로 내보내기(지금은 디스크 이미지만, 예: --volume $DJC_HOME/mnt)
.build/debug/djc usb-edit --volume <마운트> (<편집.json> | --draft) --db <사본.db> [--dry-run] [--snapshot-time <ISO 8601>]   # 라이브러리가 있는 USB에 곡 더하기·빼기·갱신·재생 목록 편집(지금은 디스크 이미지만, JSON 모양은 docs/cli.md)
.build/debug/djc usb-restore --volume <마운트> [--backup <폴더>] [--discard-device-changes]   # USB 쓰기를 그 전 백업으로 되돌리기
.build/debug/djc usb-recover --volume <마운트> [--discard-temp]                             # 끝나지 않은 USB 쓰기를 마저 쓰거나 되돌리기
.build/debug/djc usb-info <볼륨|폴더> [--json]                                             # USB 읽기만: 형식·곡 수·두 형식 일치·분석 파일·경고(실물은 쓰기 금지 목록 등록 뒤에만)
.build/debug/djc lab usb-image create|attach|detach|info <이미지>   # 임시 폴더 아래 FAT32 디스크 이미지(attach는 --mount <폴더>)
.build/debug/djc lab usb-image seed --image <이미지> --from <폴더>   # 붙인 이미지에 폴더 내용을 데이터만 복사
.build/debug/djc lab usb-tree <루트>                                 # USB 트리(NFC 경로·크기·SHA-256, 마지막 줄 ._ 수)
.build/debug/djc lab usb-diff <A> <B> [--onelibrary|--device-library] [--files] [--mtime] [--anlz] [--ignore-anlz-folder] [--ignore-ids] [--skip …]   # 두 USB 폴더 비교(모델·파일 트리·ANLZ 태그, 값·경로 없이, --mtime은 FAT 2초 단위)
.build/debug/djc lab usb-rebuild <USB 폴더> <출력 폴더>              # USB를 읽은 모델로 DB 셋만 새 내보내기 모양으로 다시 만들기(usb-diff --ignore-ids로 비교)
.build/debug/djc lab usb-anlz-relocate <USB 사본> --track <id> --folder <P???/????????> [--db-only|--files-only|--decoy-slot0|--cue-variant]   # 기기 실험용: 한 곡의 분석 파일·DB 경로를 어긋나게(임시 폴더 사본에만)
.build/debug/djc lab usb-write-check --volume <마운트>               # 합성 묶음을 디스크 이미지에 써 보고 다시 붙여 검증
.build/debug/djc lab usb-commit-crash --image <빈 이미지> --repeat N # 쓰는 도중 강제 분리 → 회복을 되풀이
```

- USB 쓰기 시험은 `usb-image`로 만든 디스크 이미지에만 한다. rekordbox가 켜져 있으면 이미지 명령(만들기·붙이기·채우기·쓰기 시험)은 거부된다. 이미지·마운트 지점은 임시 폴더 아래만, `DJC_HOME=<임시 폴더>`를 함께 준다.
- 앱 개발용 실행 인자: `--db <스냅샷>`(그 사본을 연다), `--select <ContentID>`(곡을 골라 둔다).
- 환경 변수: `DJC_HOME`(초안·백업 폴더를 바꿈), `DJC_REKORDBOX_DIR`(rekordbox 폴더 사본), `DJC_DB`(열 스냅샷), `DJC_IDLE_SECONDS`(재생 멈춘 뒤 엔진 끄기까지, 설정 › 일반보다 먼저).

## 검증 (작업이 끝났다고 말하기 전에)

- `scripts/check.sh`가 통과해야 한다(빌드·테스트·커버리지 목표).
- 테스트 먼저(TDD): 버그는 실패하는 테스트로 재현한 뒤 고친다. 새 규칙은 테스트를 먼저 쓰고 빨간색을 본 뒤 구현한다.
  - 순수 규칙(큐 편집·루프·게인·재생 예약) → `Tests/DJCDomainTests`
  - rekordbox 쓰기 → `Tests/RekordboxKitTests`. 구조만 있는 rekordbox 7.2.18 DB(`RekordboxFixture`)와 합성 분석 파일(`AnlzBuilder`)로 한다. 새 쓰기 규칙은 실험 곡·날짜를 적은 골든 테스트로 남긴다.
  - 덱·반영 흐름 → `Tests/DJCrateTests`. 가짜 오디오(`FakeDeckAudio`)·메모리 저장소(`DeckStorage.memory`)·가짜 창(`ScriptedPrompter`)
- 소리·실제 UI·rekordbox 쓰기 전 과정은 앱 자가 테스트로 확인한다. **디버그 빌드에만 있다**(`.build/debug/DJCrate`). 초안이 사용자 것과 섞이지 않게 항상 `DJC_HOME=<임시 폴더>`를 준다:

| 인자 | 확인하는 것 | 추가 조건 |
|---|---|---|
| `--itunes-selftest` | iTunes 목록 순서·읽기 전용 제한·덱 핫큐·태그 초안·DB 불변 | `DJC_ITUNES_FIXTURE=<폴더> swift test --filter ITunesFixtureCapture` 합성 사본을 `DJC_REKORDBOX_DIR`·`--db`로 |
| `--write-selftest` | 반영(미리 보기·쓰기·조용한 다시 읽기·되돌리기) 전 과정. 재생 목록 초안(새 폴더·목록, 있던 목록에 곡)도 만들어 함께 쓰고 되돌린다 | `DJC_REKORDBOX_DIR` 사본 필수. 합성 사본은 `DJC_PLAYLIST_FIXTURE=<폴더> swift test --filter PlaylistWriteFixtureCapture` |
| `--loop-selftest` | 활성 루프·즉석 루프·½·핫큐 저장·나가기 | `--select`로 활성 루프 있는 곡 |
| `--loop-audio-selftest` | 루프 이음새가 샘플 단위로 맞는지(램프 WAV) | — |
| `--hotcue-click-selftest` | 2초 스크럽·관성이 실제 파형 모니터에 도착하는지(21·42개), 관성 누출과 핫큐 클릭·이동 확인(물리 트랙패드의 OS 감속·클릭 억제는 별도 확인) | `EditLayoutFixtureCapture` 합성 라이브러리를 `DJC_REKORDBOX_DIR`·`--db`로 |
| `--jump-audio-selftest` | 재생 퀀타이즈 핫큐 점프가 박 경계에서 샘플 단위로 넘어가는지(램프 WAV, ¼·1박·루프 핫큐·다시 누름, `--jump-bpm=180`으로 빠른 곡도 확인) | — |
| `--metronome-jump-selftest` | 핫큐 점프 직후 60→180 BPM 그리드의 클릭 간격·강박 전환(실제 오디오) | — |
| `--metronome-selftest` | 메트로놈 클릭이 빠지지 않는지(실제 엔진으로 12초 재생해 클릭 수를 셈) | — |
| `--switch-selftest` | 곡 전환·일시정지 뒤 소리 | — |
| `--scroll-perf` | 재생 중 목록 스크롤 때 프레임 간격 | `--perf-hide=zoom,label,…`로 A/B |
| `--edit-selftest` | 곡 편집 창: 이음새 미리 듣기(실제 재생)·렌더·추가한 곡으로 이동·덱에 편집본 | `EditLayoutFixtureCapture` 합성 라이브러리를 `DJC_REKORDBOX_DIR`·`--db`로 |
| `--usb-selftest` | 합성 라이브러리 → 디스크 이미지 내보내기 → 꺼내기·다시 붙여 확인 → 되돌리기("USB 시험 통과" 줄) | rekordbox 꺼짐, `DJC_HOME` 임시 폴더, `--db <스냅샷 사본>`(`DJC_HOME`은 스냅샷을 옮기지 않는다). 앱 없이 같은 흐름: `DJC_USB_SELFTEST_SCRATCH=<임시 폴더> swift test --filter UsbSelfTestScenarioCapture` |

예: `DJC_HOME=$(mktemp -d) .build/debug/DJCrate --db <스냅샷> --select 32395449 --loop-selftest 2>&1 | grep "루프 시험"`

- USB 쓰기 전 과정은 디스크 이미지로 확인한다(임시 `DJC_HOME`, rekordbox가 꺼져 있을 때만): `lab usb-image create` → `attach --mount` → `lab usb-write-check`("USB 쓰기 시험 통과" 줄) → `usb-restore`로 쓰기 전 트리(`lab usb-tree` 비교) → `detach`. 강제 분리는 `lab usb-commit-crash --image <붙이지 않은 빈 이미지>`("N/N 파일마다 옛것 또는 새것, 회복 N/N" 줄). 내보내기는 붙인 빈 이미지에 `usb-export --dry-run` → `usb-export`("결과: 썼습니다" 줄) → `usb-info --json`(두 형식, `roundTripOK` true, 경고 없음) → `lab usb-rebuild`·`lab usb-diff … --ignore-ids`("차이 0"). 수정은 내보낸 이미지에 `usb-edit … --dry-run`(트리 그대로) → `usb-edit`(편집별 결과 줄) → `usb-info --json` → `lab usb-rebuild`·`usb-diff --ignore-ids`("차이 0") → `usb-restore`(트리가 쓰기 전과 같음). 끝나면 `hdiutil info`에 그 폴더의 이미지가 남지 않아야 한다.
- 결과는 추측하지 말고 명령 출력(통과/실패 줄, 수치)을 보여 준다.
- 새 앱 인자는 `--이름=값` 한 덩어리로 만든다. 값을 따로 쓴 `--perf-hide zoom`은 AppKit이 값을 열 파일로 보고 앱이 멈췄다.

## 구조

의존 방향은 한쪽뿐이다: 앱·CLI → DJCStorage → RekordboxKit → DJCDomain, DJCAnalysis → DJCDomain (`Package.swift` 주석).

- `Sources/DJCDomain/` — 입출력 없는 규칙·모델. `Cue/`(초안·큐 편집 규칙), `Grid/`(그리드 초안·따라가기), `Playback/`(루프 규칙·`LoopPlanner`·`PlaybackSchedule`), `Edit/`(곡 편집: 마디 구간 → 출력 시간표·그리드·큐), `Library/`(곡 행·필터·게인 정책), `Settings/`(설정 이름·기본값, 덱 단축키 표), `Comment/`, `Tags/`
- `Sources/RekordboxKit/` — rekordbox 형식. DB(`CipherDatabase`), 쓰기(`RekordboxWriter+*`, `RekordboxGridWriter`, `RekordboxCompatibility`), ANLZ, 스냅샷, `Export/`(XML·반영 계획), `Library/`
- `Sources/DJCStorage/` — DJCrate 자신의 파일: 초안·추가한 곡·반영 묶음·경로(`DJCPaths`)
- `Sources/DJCAnalysis/` — 파형·그리드 추정·조성·음량·섹션, 곡 편집 렌더(`EditRenderer`)
- `Sources/DJCrate/` — SwiftUI+AppKit 앱
  - `Deck/`: `DeckModel`(+Transport·Loops·Cues·Grid·Gain·Key), `Audio/`(`DeckAudio`, `DeckAudioEngine` 프로토콜), `Views/`, `Waveform/`
  - `Library/`: `LibraryStore`(+Writing·Staging·Tags), `TrackTable`(NSTableView), 태그 편집
  - `Reflection/`: `ReflectionCoordinator`(미리 보기 → 확인 → 쓰기 → 토스트), 토스트, XML 연동
  - `App/`: 창·사이드바·`KeyRouter`(단축키). `Settings/`: 설정 창(⌘,)·설정 저장소(`SettingsStore`, 이름·기본값은 `DJCDomain/Settings`). `Diagnostics/`: 자가 테스트·성능 기록(디버그 전용)
- USB 라이브러리(`.claude/rules/usb-write.md`, `docs/usb-internals.md`)
  - `Sources/DJCDomain/Usb/`: 형식·확인 안 된 규칙(`UsbProvisionalRule`)·볼륨 정책·실물 쓰기 관문·막힘·오류·USB 경로 규칙(`UsbLayout`)
  - `Sources/RekordboxKit/Usb/`: USB 루트 순회·지문, OneLibrary·Device Library 읽기, ANLZ 변환. 쓰기는 `Usb/Write/`(쓰기 커버리지 80%)
  - `Sources/DJCStorage/Usb/`: USB 초안·세션·백업 경로, 실험 도구의 임시 폴더 제한(`UsbScratchPath`)
  - `Sources/DJCrate/Usb/`: USB 화면(보기·내보내기·고치기)
- `Sources/djc/` — CLI. `Commands/`(늘 쓰는 명령), `Lab/`(규칙을 알아낼 때 쓴 실험, `djc lab …`)
- `Tests/` — 타깃별 테스트 + `Support/`(rekordbox 픽스처·합성 ANLZ·합성 음원, 실데이터 없음)
- 사용자 데이터: `~/Library/Application Support/DJCrate/`
  - 초안: `cue-drafts/`, `grid-drafts/`, `gain-drafts.json`, `tag-drafts/`, `playlist-drafts.json`(재생 목록 편집, 순서대로)
  - 그 밖: `staged.json`, `snapshots/`, `rekordbox-backups/`, 캐시(`analysis/`, `waveforms/`, `loudness.json`)
  - USB: `usb-backups/`, `usb-snapshots/`(USB DB의 Mac 사본), `usb-drafts/`, `usb-sessions/`(저널·잠금), `usb-staging/`

## 핵심 설계 결정 (코드만 봐서는 모르는 것)

- 편집은 모두 **초안**(`CueDraft`·`GridDraft`·게인 초안)으로 쌓고, 반영 때만 rekordbox에 쓴다. 초안은 만들 때의 rekordbox 상태(`base`)를 들고 있어, 그 뒤 rekordbox에서 바뀐 곡은 쓰지 않는다.
- 덱·초안의 시각은 모두 **rekordbox 시간축**(음원 시각 + 인코더 지연, `RekordboxTimeline.predictedOffset`)이다. 파형만 음원 시간축이라 `timelineOffset`만큼 당겨 그린다.
- 오디오:
  - `AVAudioEngine.pause()`를 쓰지 않는다. 멈출 땐 `stop()`. pause 뒤 다시 켜면 시작 시각이 밀려 소리가 늦고 무음이 쌓인다.
  - 루프는 재생 노드에 버퍼를 예약해 샘플 단위로 잇는다. 무엇을 언제 예약할지는 `LoopPlanner`(순수, 테스트됨)가 정하고 `DeckAudio.setLoop`은 그대로 실행한다. 예약은 렌더 블록보다 앞서야 한다(그러면 되풀이 버퍼도 바퀴 중간에서 정확히 끊긴다). ½은 CDJ처럼 바로, 나가기는 이번 바퀴 끝에서.
- 화면: 재생 중 매 프레임 바뀌는 관찰 값은 큰 뷰가 읽지 않게 한다. 글자·전체 파형 재생선은 `displayTime`(15Hz), 레벨 미터는 재생 틱(`meterFrame`)으로 갱신한다.
- 그리드 쓰기는 파형 파일(`.EXT`)이 있는 곡만 한다. 분석 파일이 없는 곡은 분석 파일을 만들어 붙이고(`RekordboxWriter+Analysis`), `.DAT`만 있는 반쪽 곡은 막는다.
- 새 곡은 미리 보기를 거쳐 rekordbox 컬렉션에 직접 넣거나, 기존 호환 경로인 rekordbox XML(Import To Collection)로 넘긴다. 추가 목록에는 이미 컬렉션에 있는 경로를 넣지 않는다(기존 큐 덮어쓰기 방지). 기존 곡의 XML 경로는 큐·그리드 초안만 다루며, 직접 쓰기와 지원 범위가 다르다([안내](README.md#xml-호환-경로)).
- 설정: 이름·기본값·범위는 `SettingKeys`에 모은다. 이름은 옛 UserDefaults 키 그대로다(바꾸면 쓰던 값을 잃는다). 덱 단축키는 키 위치(키 코드)로 정하고, 기본과 다른 동작만 저장한다. ⌘·⌃·⌥ 조합과 목록 확정·이동 키(`DeckShortcuts.reservedKeys`)는 지정할 수 없다.

## 코드 스타일

- UI 문구(원문)·주석·커밋 메시지는 한국어, 식별자는 영어. 화면 문구는 `String(ui:)`·`.ui(…)`로 쓰고 영어·일본어 번역을 카탈로그(`Sources/DJCrate/Resources/Localizable.xcstrings`)에 채운다. 규칙·용어표는 `docs/i18n.md`.
화면의 편집·쓰기 용어는 아래 표를 따른다. XML 파일 안의 기존 재생 목록 이름(`DJCrate 반영`)은 유지한다.

| 동작 | 화면 용어 |
|---|---|
| 편집 이력 취소 / 다시 실행 | 실행 취소 / 실행 복귀 |
| 아직 쓰지 않은 초안 삭제 | 초안 버리기(큐·그리드·게인·태그는 대상을 함께 적음) |
| 쓰기 전 백업으로 라이브러리 전체 복원 | 쓰기 전으로 복원… |
| 초안을 rekordbox 라이브러리에 직접 쓰기 | rekordbox에 쓰기… / 쓰기 대기 |
| 정해진 연동 파일에 XML 저장 | XML 만들기 |
| DJCrate의 추가 목록에서만 빼기 | 추가 목록에서 제거 |
| rekordbox 컬렉션에서 곡 삭제 | rekordbox에서 빼기… |

- 확인 창을 열어야 하는 버튼·메뉴에는 `…`를 붙이고, 바로 실행하는 XML 만들기에는 붙이지 않는다. 최종 확인 버튼에는 붙이지 않는다.
- 툴바의 쓰기 메뉴 제목은 최소 창 폭에서도 보이도록 `rekordbox에 쓰기`로 짧게 쓴다. 메뉴 안의 항목에는 일반 말줄임표 규칙을 적용한다.
- 툴팁은 짧게 동작을 설명하고(75자 이내 권장), XML 가져오기 절차는 연동 안내 창에서 설명한다. 수식키는 `⌃⌥⇧⌘` 순서로 적는다.

- 주석은 "왜"를 짧게 한국어로. 둘레 코드의 주석 밀도와 말투에 맞춘다.
- 사용자에게 보이는 막힘·오류 이유는 무엇을 하면 되는지까지 한국어 한 문장으로 쓴다(예: "rekordbox에서 트랙 분석을 먼저 한 뒤 쓰세요").
- Swift 6 엄격 동시성. 오디오 탭·렌더 콜백은 메인 액터 밖(`nonisolated static`)에서 만든다. 메인 액터 격리를 물려받으면 오디오 스레드에서 죽는다.

## 저장소 규칙

- 브랜치:
  - `main`: 릴리스
  - `dev`: 통합
  - 작업 브랜치: `feat/…`, `fix/…`, `chore/…`, `hotfix/…`, `release/vX.Y.Z`. 이슈가 있으면 번호를 앞에 붙인다(`feat/38-playlist-write`)
  - 작업 브랜치는 `dev`에서 따고, `git merge --no-ff`로 dev에 합친다("Merge branch 'feat/…' into dev").
- 커밋 제목: `타입: 한국어 설명`(마침표 없음). 타입 = feat, fix, docs, style, design, test, refactor, build, ci, perf, chore, rename, remove. 자세한 내용은 본문에 불릿으로.
- 커밋·푸시는 요청받았을 때만 한다.
- 할 일·조사·계획은 GitHub 이슈로 관리한다(`docs/plans/`에 계획 문서를 만들지 않는다). 제목·라벨·본문·닫기 규칙은 `docs/issues.md`. 공개 저장소라 이슈에 라이브러리 사본·토큰·곡 수·개인 경로를 넣지 않는다.
- 빌드해서 앱을 바꿀 때: DJCrate가 꺼져 있으면 `scripts/build-app.sh --install`로 설치한다. **켜져 있으면 끄기 전에 사용자에게 묻는다.**

## rekordbox 실험이 필요할 때

사용자에게 rekordbox에서 그 편집을 직접 해 달라고 부탁하고(곡 이름을 받고, 끝나면 rekordbox 종료), 전후 스냅샷을 비교한다. 방법은 `docs/rekordbox-internals.md`의 "새 쓰기 경로를 여는 방법".
