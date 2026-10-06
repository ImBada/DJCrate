# AGENTS.md — DJCrate

rekordbox 7용 DJ 라이브러리 관리 macOS 앱 DJCrate(약칭 DJC, CLI `djc`, 1인용, 옛 이름 anicue). 사람·Claude Code·Codex 등 모든 에이전트가 따르는 정본이다. 기능 소개는 `README.md`(자세히는 `docs/features.md`), rekordbox 쓰기 규칙은 `docs/rekordbox-internals.md`, 구조·설계 결정은 `docs/architecture.md`, 이슈 관리 규칙은 `docs/issues.md`.

- IMPORTANT: 사용자에게 하는 말·보고·질문은 항상 한국어로 한다.

## 가장 중요한 규칙: rekordbox 라이브러리를 절대 깨뜨리지 않는다

- IMPORTANT: rekordbox 또는 rekordboxAgent가 켜져 있으면 rekordbox 라이브러리(`master.db`, `share/PIONEER/USBANLZ`)에 **절대 쓰지 않는다**. 쓰기는 `RekordboxWriter.write` 한 곳으로만 한다(사전 확인 → 전체 백업 → 한 트랜잭션 → 다시 읽어 검증 → 무결성 검사 → 실패 시 복원).
- 사전 확인(`RekordboxCompatibility`, `RekordboxWriteGuard`): rekordbox 7.2.x만, DB 구조(`djmdCue`·`contentCue` 칸이 정확히 같고 고치는 칸이 있음)·`DBVersion` 6000, 로컬 변경 카운터 ≥ 클라우드 동기화 카운터. 막힐 조건은 백업을 뜨기 전에 본다. rekordbox가 업데이트되면 `djc compat`으로 먼저 확인하고, 실험으로 규칙을 다시 확인하기 전에는 허용 목록을 넓히지 않는다.
- 라이브 DB·음원은 읽기 전용이다. 읽기는 스냅샷 사본(`LibrarySnapshot`)에서 한다.
- 시험·실험 쓰기는 **사본에만** 한다: `DJC_REKORDBOX_DIR=<사본 폴더>`, `DJC_HOME=<임시 폴더>`. 사본의 `share/PIONEER/USBANLZ`는 심볼릭 링크가 아니라 실제 복사본이어야 한다.
- 시험은 실제 라이브러리와 사용자 데이터를 절대 쓰지 않는다(#182: 시험이 실제 라이브러리로 복원해 라이브러리를 덮었다).
  - 시험 프로세스의 기본 rekordbox 폴더·DJCrate 데이터 폴더는 임시 폴더(`TestProcess.sandbox`)다. 실제 rekordbox 폴더 쓰기·복원은 쓰기 관문이 거부한다.
  - 쓰기·복원 API에 라이브 DB 기본 인자를 두지 않는다(부르는 쪽이 대상을 적는다). 앱은 `LibraryStore.rekordboxDatabase` 한 곳에서 쓰기·복원 대상을 정한다. 복원은 다른 라이브러리(`djmdProperty.DBID`)의 백업을 거부한다.
  - 시험 환경(검사 스크립트의 환경 변수, 시험 활성 조건)을 바꾸면 그 변경으로 새로 도는 시험이 무엇을 쓰는지 먼저 확인한다.
- 규칙을 확인하지 않은 쓰기(미확인 ALAC 형식, MPEG-1(32·44.1·48kHz)이 아닌 ffmpeg VBR·그 밖의 비LAME VBR·CRC가 맞지 않는 프레임이 있는 FLAC 분석 붙이기)는 막아 둔다. 새 쓰기 경로는 rekordbox 실험 → 사본 재현 → 칸 단위 일치를 확인한 뒤에만 연다(`docs/rekordbox-internals.md` 끝).
- rekordbox DB 사본(`*.db`, `-wal`, `-shm`, `snapshots/`)에는 클라우드 토큰이 들어 있다. 커밋·출력·로그 금지. `agentRegistry`의 인증값은 읽지도 옮기지도 않는다.
- rekordbox 규칙은 rekordbox 화면에서 편집한 결과 파일을 비교해서만 알아낸다. rekordbox 실행 파일(본체·rb_http_server 등)은 strings·디스어셈블을 포함해 분석하지 않는다.
- 라이선스가 없는 외부 코드·문서는 쓰지 않는다. 외부 코드를 옮기면 라이선스를 확인하고 THIRD_PARTY_NOTICES.md에 더한다.
- 내보내는 파일(USB 등)은 칸 단위로 만든다. rekordbox가 만든 파일의 페이지·표 바이트를 통째로 넣지 않는다.
- USB 쓰기는 `UsbWriter.write` 한 곳으로만 한다. rekordbox·rekordboxAgent가 켜져 있으면 USB에도 쓰지 않는다.
- USB의 DB(`exportLibrary.db`·`export.pdb`·`exportExt.pdb`)는 Mac 사본에서만 연다. USB 위에서 SQLite를 열지 않는다.
- 실물 USB 쓰기는 기본으로 꺼져 있다. 코드 관문(`UsbPhysicalWriteGate.buildEnabled`)과 실행 중 스위치(설정 › 실험실 "실물 USB 쓰기"·CLI `--allow-physical`)가 둘 다 열리고, 쓰기 금지 목록이 등록돼 있고, 사용자가 그 USB에 쓰기를 허용했고(`djc usb-allow`·사이드바), 볼륨 이름을 확인한 FAT32·MBR USB 메모리에만 쓴다(`docs/usb-internals.md` §12). 시험·에이전트는 이 Mac에 꽂힌 실제 볼륨에 쓰지 않는다(나열·읽기 전용 확인만). 시험 쓰기는 `djc lab usb-image`로 만든 디스크 이미지나 임시 폴더 루트에 주입한 가짜 볼륨에만 한다(시험 프로세스는 관문이 열려도 임시 폴더 밖에 쓰지 않는다). 이미지·lab 출력은 임시 폴더 아래만(`UsbScratchPath`).
- `PIONEER/extracted`·`PIONEER/CDP`·`djprofile.nxs`는 열거·읽기·복사하지 않는다.

## 명령

```bash
scripts/check.sh                     # 저장소 전반 영향·명시 요청 때 전체 검사: 디버그·릴리스 앱 + 번역 + 전체 테스트 + 커버리지 목표(쓰기 80%, 코어 60%)
scripts/check.sh --quick --filter 'WriteGuardTests'  # 기본·최종 검증: 변경에 관련된 시험, 같은 계측 빌드 재사용
scripts/check.sh --stress            # SQLCipher 초기화·cold-open 관련 변경: 100개 새 프로세스 × 32스레드
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
.build/debug/djc xml-export --db <사본.db> --out <파일.xml> (--share <rekordbox 폴더>/share | --no-analysis) [--overwrite] [--dry-run]   # 라이브러리 전체를 rekordbox XML 한 파일로(읽기만, 지정한 파일만 씀, rekordbox 폴더·USB PIONEER·DJCrate 데이터 폴더·연동 XML 자리는 거부)
.build/debug/djc lab                                   # 실험 명령 목록(sql·loop-repro·seekinfo-check …)
.build/debug/djc lab sql <사본.db> "SELECT …"           # 사본에 읽기 전용 질의
.build/debug/djc usb-export --volume <마운트> --db <사본.db> (--playlist <ID>… | --tracks <ID,…>) [--dry-run] [--snapshot-time <ISO 8601>] [--allow-physical --confirm <볼륨 이름>]   # 빈 USB에 두 형식으로 내보내기(시험은 디스크 이미지만, 예: --volume $DJC_HOME/mnt)
.build/debug/djc usb-edit --volume <마운트> (<편집.json> | --draft) --db <사본.db> [--dry-run] [--snapshot-time <ISO 8601>] [--allow-physical --confirm <볼륨 이름>]   # 라이브러리가 있는 USB에 곡 더하기·빼기·갱신·재생 목록 편집(시험은 디스크 이미지만, JSON 모양은 docs/cli.md)
.build/debug/djc usb-migrate --volume <마운트> [--dry-run] [--allow-physical --confirm <볼륨 이름>]       # Device Library만 있는 USB에 OneLibrary 더하기(원래 파일 그대로, 시험은 디스크 이미지만)
.build/debug/djc usb-restore --volume <마운트> [--backup <폴더>] [--discard-device-changes]   # USB 쓰기를 그 전 백업으로 되돌리기
.build/debug/djc usb-recover --volume <마운트> [--discard-temp]                             # 끝나지 않은 USB 쓰기를 마저 쓰거나 되돌리기
.build/debug/djc usb-info <볼륨|폴더> [--json]                                             # USB 읽기만: 형식·곡 수·두 형식 일치·분석 파일·경고(실물은 쓰기 금지 목록 등록 뒤에만)
.build/debug/djc usb-deny --volume <마운트>                                                # 쓰면 안 되는 USB를 쓰기 금지 목록에(목록 파일만, 사용자가 직접)
.build/debug/djc usb-allow --volume <마운트> [--remove]                                    # 이 실물 USB에 쓰기 허용·거두기(목록 파일만, 사용자가 직접)
.build/debug/djc lab usb-image create|attach|detach|info <이미지>   # 임시 폴더 아래 FAT32 디스크 이미지(attach는 --mount <폴더>)
.build/debug/djc lab usb-image seed --image <이미지> --from <폴더>   # 붙인 이미지에 폴더 내용을 데이터만 복사
.build/debug/djc lab usb-tree <루트>                                 # USB 트리(NFC 경로·크기·SHA-256, 마지막 줄 ._ 수)
.build/debug/djc lab usb-diff <A> <B> [--onelibrary|--device-library] [--files] [--mtime] [--anlz] [--ignore-anlz-folder] [--ignore-ids] [--skip …]   # 두 USB 폴더 비교(모델·파일 트리·ANLZ 태그, 값·경로 없이, --mtime은 FAT 2초 단위)
.build/debug/djc lab usb-rebuild <USB 폴더> <출력 폴더>              # USB를 읽은 모델로 DB 셋만 새 내보내기 모양으로 다시 만들기(usb-diff --ignore-ids로 비교)
.build/debug/djc lab usb-migrate-check <USB 폴더>                   # 두 형식이 있는 USB(골든 사본)의 pdb를 옮기기 변환해 그 USB의 OneLibrary와 칸 비교
.build/debug/djc lab usb-fields <USB 폴더> --out <파일.json>         # 두 리더가 읽은 칸을 해시로(외부 파서 대조 scripts/usb-parser-compare.py, docs/usb-internals.md §8.2)
.build/debug/djc lab usb-anlz-relocate <USB 사본> --track <id> --folder <P???/????????> [--db-only|--files-only|--decoy-slot0|--cue-variant]   # 기기 실험용: 한 곡의 분석 파일·DB 경로를 어긋나게(임시 폴더 사본에만)
.build/debug/djc lab usb-write-check --volume <마운트>               # 합성 묶음을 디스크 이미지에 써 보고 다시 붙여 검증
.build/debug/djc lab usb-commit-crash --image <빈 이미지> --repeat N # 쓰는 도중 강제 분리 → 회복을 되풀이
```

- USB 쓰기 시험은 `usb-image`로 만든 디스크 이미지에만 한다. rekordbox가 켜져 있으면 이미지 명령(만들기·붙이기·채우기·쓰기 시험)은 거부된다. 이미지·마운트 지점은 임시 폴더 아래만, `DJC_HOME=<임시 폴더>`를 함께 준다.
- 앱 개발용 실행 인자: `--db <스냅샷>`(그 사본을 연다), `--select <ContentID>`(곡을 골라 둔다).
- 환경 변수: `DJC_HOME`(초안·백업·캐시(`waveforms/`·`analysis/`·`loudness.json`) 폴더를 바꿈. 스냅샷은 옮기지 않는다), `DJC_REKORDBOX_DIR`(rekordbox 폴더 사본), `DJC_DB`(열 스냅샷), `DJC_IDLE_SECONDS`(재생 멈춘 뒤 엔진 끄기까지, 설정 › 일반보다 먼저).

## 검증 (작업이 끝났다고 말하기 전에)

- 기본 검증과 최종 검증은 변경 영향에 관련된 시험만 골라 진행한다. 관련 시험으로 TDD와 회귀 확인을 마치고 리뷰한다. 전체 검사는 영향이 저장소 전반에 걸치거나 사용자가 명시적으로 요청한 경우에만 실행한다. `scripts/check.sh` full의 디버그·릴리스 앱 빌드, 번역, 전체 안전·쓰기 시험, 커버리지 목표(쓰기 80%, 코어 60%)는 유지한다.
- `scripts/check.sh`는 따로 주지 않으면 임시 `DJC_REKORDBOX_DIR`·`DJC_HOME`을 쓰고, 검사 전후 실제 rekordbox 라이브러리 파일(`master.db`·`masterPlaylists6.xml`·분석 파일)이 바뀌면 종료 코드 3으로 실패한다. `swift test`를 직접 돌릴 때도 두 변수를 임시 폴더로 준다.
- `--quick --filter <정규식>`은 관련 시험만 실행하며 릴리스·번역·커버리지 보고를 생략한다. 빈 필터·선택된 시험 0개·모든 시험 건너뜀·잘못된 인자는 실패해야 한다. 변경 영향에 충분한 시험 범위를 선택해 통과 결과로 작업 완료를 확인하고, 실제 명령·필터·검증 범위를 보고한다.
- 통과 결과는 같은 검증 대상 코드·툴체인·빌드 설정·시험 환경일 때만 재사용한다. 코드·의존성·설정·환경이 바뀌면 그 영향에 관련된 시험만 다시 검증하고, 영향 없는 시험은 반복하지 않는다. 단순 병합으로 커밋만 바뀌고 검증한 코드와 조건이 같으면 검사를 중복 실행하지 않는다. 원래 로그와 실제 종료 코드로 재사용 근거를 남긴다.
- SQLCipher 초기화(`CipherDatabase`), `CipherLab`, cold-open 경쟁에 관련된 변경은 `scripts/check.sh --stress`도 반드시 통과해야 하며, 별도 수동 CI에서도 실행한다. stress 필터는 cold-open 경쟁 시험 1개와 같은 파일의 설정 계약 시험 3개를 함께 실행한다. 일반 회귀는 새 프로세스 4개, stress는 100개이며 각각 32스레드·동시 프로세스 4개 상한을 유지한다. `DJC_CIPHER_STRESS`는 미설정·`0`이면 일반, `1`이면 stress이고 그 밖의 값은 실패한다.
- 같은 checkout에서 Swift 빌드·시험·성능 측정 명령을 동시에 실행하지 않는다. 공유 작업트리는 담당자와 실행 슬롯을 합의하고, 단계별 진행 로그를 남긴다. 전체 명령을 고정 240초에 끊고 반복하지 않는다. 오디오 실행은 빌드와 분리해 본인이 소유한 `/tmp/djc-audio.lock` 안에서 5분 이하로 끝낸다. 자세한 운영·측정 기준은 `docs/ci.md`를 따른다.
- 테스트 먼저(TDD): 버그는 실패하는 테스트로 재현한 뒤 고친다. 새 규칙은 테스트를 먼저 쓰고 빨간색을 본 뒤 구현한다.
  - 순수 규칙(큐 편집·루프·게인·재생 예약) → `Tests/DJCDomainTests`
  - rekordbox 쓰기 → `Tests/RekordboxKitTests`. 구조만 있는 rekordbox 7.2.18 DB(`RekordboxFixture`)와 합성 분석 파일(`AnlzBuilder`)로 한다. 새 쓰기 규칙은 실험 곡·날짜를 적은 골든 테스트로 남긴다.
  - 덱·반영 흐름 → `Tests/DJCrateTests`. 가짜 오디오(`FakeDeckAudio`)·메모리 저장소(`DeckStorage.memory`)·가짜 창(`ScriptedPrompter`)
  - 시험은 사용자 초안·백업 폴더를 쓰지 않는다. 폴더를 주입하고(`directory:`·`backupDirectory:`), 앱 기본 폴더(`DJCPaths`)를 써야 하는 시험만 `.enabled(if: LiveDraftHome.isIsolated)`로 `DJC_HOME`이 있을 때 돌린다. `scripts/check.sh`는 `DJC_HOME`이 없으면 실행 로그 폴더 아래를 쓴다.
- 소리·실제 UI·rekordbox 쓰기 전 과정은 앱 자가 테스트로 확인한다. **디버그 빌드에만 있다**(`.build/debug/DJCrate`). 초안이 사용자 것과 섞이지 않게 항상 `DJC_HOME=<임시 폴더>`를 준다:

| 인자 | 확인하는 것 | 추가 조건 |
|---|---|---|
| `--itunes-selftest` | iTunes 목록 순서·읽기 전용 제한·덱 핫큐·태그 초안·DB 불변 | `DJC_ITUNES_FIXTURE=<폴더> swift test --filter ITunesFixtureCapture` 합성 사본을 `DJC_REKORDBOX_DIR`·`--db`로 |
| `--write-selftest` | 반영(미리 보기·쓰기·조용한 다시 읽기·되돌리기) 전 과정. 재생 목록 초안(새 폴더·목록, 있던 목록에 곡)도 만들어 함께 쓰고 되돌린다 | `DJC_REKORDBOX_DIR` 사본 필수. 합성 사본은 `DJC_PLAYLIST_FIXTURE=<폴더> swift test --filter PlaylistWriteFixtureCapture` |
| `--loop-selftest` | 활성 루프·즉석 루프·½·핫큐 저장·나가기 | `--select`로 활성 루프 있는 곡 |
| `--loop-audio-selftest` | 루프 이음새가 샘플 단위로 맞는지(램프 WAV) | — |
| `--hotcue-click-selftest` | 2초 스크럽·관성이 실제 파형 모니터에 도착하는지(21·42개), 관성 누출과 핫큐 클릭·이동 확인(물리 트랙패드의 OS 감속·클릭 억제는 별도 확인) | `EditLayoutFixtureCapture` 합성 라이브러리를 `DJC_REKORDBOX_DIR`·`--db`로 |
| `--scrub-hotcue-selftest` | 확대 파형을 끄는 중 핫큐 키: 진짜 키 이벤트가 KeyRouter에 오지 않는 것, 빈 칸 찍기·저장된 칸으로 옮겨 이어 끌기·놓은 뒤 재생(키는 합성 키보드 상태) | `EditLayoutFixtureCapture` 합성 라이브러리를 `DJC_REKORDBOX_DIR`·`--db`로. 덱 창이 키 창이 돼야 한다(못 하면 exit 2) |
| `--jump-audio-selftest` | 재생 퀀타이즈 핫큐 점프가 박 경계에서 샘플 단위로 넘어가는지(램프 WAV, ¼·1박·루프 핫큐·다시 누름, `--jump-bpm=180`으로 빠른 곡도 확인) | — |
| `--flip-selftest` | Flip 기록이 들린 소리와 샘플 단위로 같은지(램프 WAV로 퀀타이즈 끔·켬 핫큐, 루프 핫큐·나가기를 기록 → 섞지 않고 렌더해 곡 믹서 출력과 이음새·프레임 비교), 출력 장치 변경이 점프로 남지 않는지("Flip 시험 통과" 줄) | — |
| `--metronome-jump-selftest` | 핫큐 점프 직후 60→180 BPM 그리드의 클릭 간격·강박 전환(실제 오디오) | — |
| `--metronome-selftest` | 메트로놈 클릭이 빠지지 않는지(실제 엔진으로 12초 재생해 클릭 수를 셈) | — |
| `--switch-selftest` | 곡 전환·일시정지 뒤 소리 | — |
| `--scroll-perf` | 재생 중 목록 스크롤 때 프레임 간격 | `--perf-hide=zoom,label,…`로 A/B |
| `--resize-perf=all` | 활성화·입력·재생 없이 가로·세로 40단계씩 창 크기 변경. 단계별 크기 요청·레이아웃/표시 처리·확대 파형 Canvas 시간·본문 횟수, 왕복별 프레임 간격 중앙값/최댓값·메인 CPU·부하를 JSON으로 기록. 첫 왕복은 준비 측정. `--resize-perf=width,height`, `--resize-perf-repeats=3`, `--resize-perf-capture=<폴더>`로 축·반복·해당 창 JPEG 캡처 지정 | `UIPerfFixtureCapture` 합성 라이브러리와 `DJC_DB`·`DJC_REKORDBOX_DIR`·임시 `DJC_HOME`, `/tmp/djc-heavy.lock` 필수. 실제 가장자리 드래그·표시 FPS는 별도 확인 |
| `--ui-perf=all` | 조작마다(사이드바·인스펙터 열고 닫기, 창 크기, 스크롤, 선택, 사이드바 항목, 정렬, 검색, 덱에 올리기, 확대·축소, 스크럽, 재생, 태그 시트, 곡 편집 창, 쓰기 미리 보기) 메인 스레드 일한 시간·프레임 간격. `--ui-perf=sidebar,sort`처럼 골라 재고, 조작마다 관심 지점 구간을 남겨 `xctrace` Time Profiler로 원인을 나눠 본다. 조작마다 주요 뷰 본문이 다시 계산된 횟수(`PerfProbe.body`)와 메인 스레드 CPU 시간도 찍고, `--perf-trace-body`는 다시 계산된 이유를 찍는다. `grid`(그리드 일괄 추정 중 메인 스레드)·`drafts`·`capture`는 `all`에 없다. `--ui-perf-delay=<초>`는 조작 전에 기다려 `xctrace record --attach <PID>`를 붙일 시간을 준다 | `DJC_UI_PERF_FIXTURE=<폴더> swift test --filter UIPerfFixtureCapture` 합성 라이브러리를 `DJC_REKORDBOX_DIR`·`--db`로 |
| `--edit-selftest` | 곡 편집 창: 창 재생기(스페이스바·시킹·이음새 듣기, 덱은 그대로)·넣기·자르기·복제·옮기기·지우기와 편집 메뉴 실행 취소·확대 키·실제 마우스 끌기(클립 끝 다듬기·원곡 구간 끌어 넣기, 앱이 앞에 있을 때만)·렌더·추가한 곡으로 이동·덱에 편집본 | `EditLayoutFixtureCapture` 합성 라이브러리를 `DJC_REKORDBOX_DIR`·`--db`로 |
| `--usb-selftest` | 합성 라이브러리 → 디스크 이미지 내보내기 → 꺼내기·다시 붙여 확인 → USB 편집(곡 빼기·목록 만들기·이름 바꾸기 초안 → 미리 보기 → 쓰기 → 다시 읽기 → 되돌리기, "USB 시험 편집 통과" 줄) → 되돌리기 → Device Library만 내보내기·OneLibrary 더하기·원래 파일 SHA-256·다시 붙여 읽기·되돌리기("USB 시험 옮기기 통과" 줄) → "USB 시험 통과" 줄 | rekordbox 꺼짐, `DJC_HOME` 임시 폴더, `--db <스냅샷 사본>`(`DJC_HOME`은 스냅샷을 옮기지 않는다). 앱 없이 같은 흐름: `DJC_USB_SELFTEST_SCRATCH=<임시 폴더> swift test --filter UsbSelfTestScenarioCapture` |
| `--xml-export-capture=<폴더>` | 라이브러리 XML 내보내기(#72): 합성 라이브러리로 내보내며 진행 줄·완료 안내를 `<폴더>`에 캡처하고, 내보낸 파일의 곡·재생 목록 수와 사본 DB 불변을 확인("라이브러리 XML 시험 통과" 줄). `<폴더>`는 `DJC_HOME` 밖(데이터 폴더 안은 내보내기가 거부한다) | `DJC_XMLEXPORT_FIXTURE=<없는 폴더> swift test --filter XMLExportFixtureCapture` 합성 라이브러리를 `DJC_REKORDBOX_DIR`·`--db`로, 임시 `DJC_HOME` |

예: `DJC_HOME=$(mktemp -d) .build/debug/DJCrate --db <스냅샷> --select 32395449 --loop-selftest 2>&1 | grep "루프 시험"`

- USB 쓰기 전 과정은 디스크 이미지로 확인한다(임시 `DJC_HOME`, rekordbox가 꺼져 있을 때만): `lab usb-image create` → `attach --mount` → `lab usb-write-check`("USB 쓰기 시험 통과" 줄) → `usb-restore`로 쓰기 전 트리(`lab usb-tree` 비교) → `detach`. 강제 분리는 `lab usb-commit-crash --image <붙이지 않은 빈 이미지>`("N/N 파일마다 옛것 또는 새것, 회복 N/N" 줄). 내보내기는 붙인 빈 이미지에 `usb-export --dry-run` → `usb-export`("결과: 썼습니다" 줄) → `usb-info --json`(두 형식, `roundTripOK` true, 경고 없음) → `lab usb-rebuild`·`lab usb-diff … --ignore-ids`("차이 0"). 수정은 내보낸 이미지에 `usb-edit … --dry-run`(트리 그대로) → `usb-edit`(편집별 결과 줄) → `usb-info --json` → `lab usb-rebuild`·`usb-diff --ignore-ids`("차이 0") → `usb-restore`(트리가 쓰기 전과 같음). 옮기기는 Device Library만 채운 이미지에 `usb-migrate --dry-run`(트리 그대로) → `usb-migrate`("결과: 썼습니다", 원래 파일은 `lab usb-tree`로 그대로) → `usb-info --json`(두 형식, `roundTripOK` true, 경고 없음) → `lab usb-rebuild`·`usb-diff --ignore-ids`("차이 0") → `usb-restore`(트리가 옮기기 전과 같음). 끝나면 `hdiutil info`에 그 폴더의 이미지가 남지 않아야 한다.
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
  - 초안: `cue-drafts/`, `grid-drafts/`, `gain-drafts.json`, `tag-drafts/`, `artwork-drafts/`(앨범아트 초안과 고른 앨범아트 사본), `playlist-drafts.json`(재생 목록 편집, 순서대로)
  - `damaged-drafts/`: 읽지 못한 초안 파일(합치기 초안 `merge-drafts.json`·추가 목록 `staged.json` 포함)을 지우거나 빈 값으로 덮지 않고 옮겨 둔 곳(앱이 읽기·저장할 때 옮기고 목록 위에 알린다)
  - 그 밖: `staged.json`, `snapshots/`, `rekordbox-backups/`, 캐시(`analysis/`, `waveforms/`, `loudness.json`)
  - USB: `usb-backups/`, `usb-snapshots/`(USB DB의 Mac 사본), `usb-drafts/`, `usb-sessions/`(저널·잠금), `usb-staging/`

## 핵심 설계 결정 (코드만 봐서는 모르는 것)

- 편집은 모두 **초안**(`CueDraft`·`GridDraft`·게인 초안)으로 쌓고, 반영 때만 rekordbox에 쓴다. 초안은 만들 때의 rekordbox 상태(`base`)를 들고 있어, 그 뒤 rekordbox에서 바뀐 곡은 쓰지 않는다.
- 덱·초안의 시각은 모두 **rekordbox 시간축**(음원 시각 + 인코더 지연, `RekordboxTimeline.predictedOffset`)이다. 파형만 음원 시간축이라 `timelineOffset`만큼 당겨 그린다.
- 오디오:
  - `AVAudioEngine.pause()`를 쓰지 않는다. 멈출 땐 `stop()`. pause 뒤 다시 켜면 시작 시각이 밀려 소리가 늦고 무음이 쌓인다.
  - 출력 장치를 여는 엔진 호출(`mainMixerNode`·`outputNode`)은 메인 스레드에서 하지 않는다. coreaudiod가 멈추면 앱이 첫 화면 전에 멈췄다(#142). 엔진 그래프는 `AudioEngineQueue`에서 만들어 넘겨받는다.
  - 루프는 재생 노드에 버퍼를 예약해 샘플 단위로 잇는다. 무엇을 언제 예약할지는 `LoopPlanner`(순수, 테스트됨)가 정하고 `DeckAudio.setLoop`은 그대로 실행한다. 예약은 렌더 블록보다 앞서야 한다(그러면 되풀이 버퍼도 바퀴 중간에서 정확히 끊긴다). ½은 CDJ처럼 바로, 나가기는 이번 바퀴 끝에서.
- 화면: 재생 중 매 프레임 바뀌는 관찰 값은 큰 뷰가 읽지 않게 한다. 글자·전체 파형 재생선은 `displayTime`(15Hz), 레벨 미터는 재생 틱(`meterFrame`)으로 갱신한다.
- 그리드 쓰기는 파형 파일(`.EXT`)이 있는 곡만 한다. 분석 파일이 없는 곡은 분석 파일을 만들어 붙이고(`RekordboxWriter+Analysis`), `.DAT`만 있는 반쪽 곡은 막는다.
- 새 곡은 미리 보기를 거쳐 rekordbox 컬렉션에 직접 넣거나, 기존 호환 경로인 rekordbox XML(Import To Collection)로 넘긴다. 추가 목록에는 이미 컬렉션에 있는 경로를 넣지 않는다(기존 큐 덮어쓰기 방지). 기존 곡의 XML 경로는 큐·그리드 초안만 다루며, 직접 쓰기와 지원 범위가 다르다([안내](docs/features.md#xml-호환-경로)).
- 설정: 이름·기본값·범위는 `SettingKeys`에 모은다. 이름은 옛 UserDefaults 키 그대로다(바꾸면 쓰던 값을 잃는다). 덱 단축키는 키 위치(키 코드)로 정하고, 기본과 다른 동작만 저장한다. ⌘·⌃·⌥ 조합과 목록 확정·이동 키(`DeckShortcuts.reservedKeys`)는 지정할 수 없다.

## 코드 스타일

- UI 문구(원문)·주석·커밋 메시지는 한국어, 식별자는 영어. 화면 문구는 `String(ui:)`·`.ui(…)`로 쓰고 영어·일본어 번역을 카탈로그(`Sources/DJCrate/Resources/Localizable.xcstrings`)에 채운다. 규칙·용어표는 `docs/i18n.md`.
화면의 편집·쓰기 용어는 아래 표를 따른다. XML 파일 안의 기존 재생 목록 이름(`DJCrate 반영`)은 유지한다.

| 동작 | 화면 용어 |
|---|---|
| 편집 이력 취소 / 다시 실행 | 실행 취소 / 실행 복귀 |
| 아직 쓰지 않은 초안 삭제 | 초안 버리기(큐·그리드·게인·태그·앨범아트는 대상을 함께 적음) |
| 쓰기 전 백업으로 라이브러리 전체 복원 | 쓰기 전으로 복원… |
| 초안을 rekordbox 라이브러리에 직접 쓰기 | rekordbox에 쓰기… / 쓰기 대기 |
| 정해진 연동 파일에 XML 저장 | XML 만들기 |
| 저장 위치를 골라 라이브러리 전체를 XML 한 파일로 내보내기(읽기만) | 라이브러리 XML 내보내기… |
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
