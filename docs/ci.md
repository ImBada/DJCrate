# 빌드·테스트 CI

`.github/workflows/check.yml`은 실행 계기에 따라 검사 범위가 다르다. `dev` 푸시(작업 브랜치를 합칠 때마다)는 `swift test`로 단위 테스트만 돌리고, PR·`main` 푸시·수동 실행(`workflow_dispatch`)은 전체 검사를 두 러너에 나눠 동시에 실행한다. `coverage`는 커버리지 계측 디버그 앱·CLI·테스트 빌드, 번역 검사, 전체 테스트 실행·줄 커버리지 목표(쓰기 80%, 코어 60%)를 맡고, `release`는 릴리스 앱 빌드를 맡는다. 테스트 수와 커버리지는 Actions의 Job summary에 남긴다. 오디오·UI 앱 자가 테스트, 앱 설치·서명·배포는 실행하지 않는다.

수동 실행에서 `run_stress=true`를 선택하면 별도 러너의 `stress` 검사를 추가한다. 기본값은 `false`이며 푸시·PR이나 자동 스케줄로 stress를 실행하지 않는다. 관련 변경의 수동 stress CI에는 이 입력을 켜야 한다.

마지막 `빌드·테스트·커버리지` job은 기존 필수 체크 이름을 유지한다. 해당 실행의 모든 검사 job이 성공해야 통과하며, 실패·취소·미실행은 통과시키지 않는다. 한 검사 실패로 다른 검사 로그를 잃지 않도록 matrix의 `fail-fast`는 끈다.

로컬·릴리스 배포에서 인자 없이 실행하는 `scripts/check.sh`는 여전히 전체 검사를 순서대로 실행한다. CI 분할용 `--coverage`는 릴리스 빌드만 제외하고, `--release`는 릴리스 빌드만 실행한다. 두 명령을 같은 작업 폴더에서 동시에 실행하지 않는다. CI에서는 서로 다른 러너와 `.build`를 사용하므로 SwiftPM 잠금·산출물이 충돌하지 않는다.

## 로컬 검증 운영

기본 검증과 최종 검증은 변경 영향에 관련된 시험만 골라 진행한다. 관련 시험으로 실패를 재현하고 구현 뒤 같은 시험과 영향 범위의 회귀 시험을 확인한 다음 리뷰한다(TDD). 전체 검사는 영향이 저장소 전반에 걸치거나 사용자가 명시적으로 요청한 경우에만 실행한다. 전체 검사 명령의 디버그·릴리스 앱, 번역, 전체 안전·쓰기 시험과 쓰기 80%·코어 60% 커버리지 목표는 유지한다.

| 명령 | 범위 | 쓰임 |
|---|---|---|
| `scripts/check.sh` | 디버그·릴리스 앱, 번역, 전체 시험, 커버리지 보고·목표 | 저장소 전반 영향·명시 요청 때 전체 검사 |
| `scripts/check.sh --coverage` | full에서 릴리스 빌드만 제외 | 별도 러너의 `--release`와 함께 전체 CI 구성 |
| `scripts/check.sh --release` | 릴리스 앱 빌드만 | 별도 러너의 `--coverage`와 함께 전체 CI 구성 |
| `scripts/check.sh --quick --filter 'WriteGuardTests'` | 필터에 맞는 관련 시험만 | 기본·최종 변경 영향 검증 |
| `scripts/check.sh --stress` | `CipherColdOpenTests` 필터(경쟁 1개·설정 계약 3개), `DJC_CIPHER_STRESS=1` | 처음 열기 경쟁의 별도 스트레스 검증 |

quick과 stress는 `swift build --build-tests --enable-code-coverage`의 같은 계측 디버그 빌드를 재사용하고, 릴리스 빌드·번역·커버리지 보고를 실행하지 않는다. quick의 필터는 Swift 시험 필터 정규식이며, 빈 필터·선택된 시험 0개·잘못된 인자는 성공시키지 않는다. quick·stress에서 모든 시험을 건너뛰어 실제 통과한 시험이 없는 경우도 실패한다. `--stress`는 단독으로 사용한다. 변경 영향에 충분한 시험 범위를 선택해 통과 결과로 작업 완료를 확인하고, 실제 명령·필터·검증 범위를 보고한다.

일반 cold-open 회귀는 새 프로세스 4개 × 32스레드, stress는 새 프로세스 100개 × 32스레드이고, 두 경우 모두 동시에 실행하는 프로세스는 최대 4개다. `DJC_CIPHER_STRESS`는 미설정·`0`이면 일반, `1`이면 stress이며, 빈 문자열 등 나머지 값은 실패한다. `CipherDatabase`의 SQLCipher 초기화, `CipherLab`, cold-open 경쟁 관련 변경에는 stress 통과가 필수다. 별도 수동 CI에서도 stress를 실행하며, 다른 안전·쓰기 시험과 full의 커버리지 목표는 줄이지 않는다.

### 통과 결과 재사용

같은 검증 대상 코드·툴체인·빌드 설정·시험 환경에서 얻은 통과만 재사용한다. 실행 명령·필터·환경 조건, 검증한 코드, 원래 로그·종료 코드를 함께 남긴다. 코드·의존성·설정·환경이 바뀌면 그 영향에 관련된 시험만 다시 검증하고, 영향 없는 시험은 반복하지 않는다. 단순 병합으로 커밋만 바뀌고 검증한 코드와 조건이 동일하면 검사를 중복 실행하지 않는다. 캐시 복원은 시험 통과의 근거가 아니며, 실제 실행한 범위만 검증 결과로 보고한다.

같은 checkout에서는 `swift build`, `swift test`, Swift를 호출하는 검사·번역 스크립트와 성능 측정을 동시에 실행하지 않는다. 공유 작업트리에서는 조정자에게 실행 슬롯을 받아 한 담당자만 실행하고, 다른 담당자는 같은 후보의 로그를 검토한다. 전체 검증 명령을 고정 240초에 끊어 재시작하지 말고, 빌드·시험·보고를 단계별 진행 로그와 종료 코드로 관찰한다. 오디오 실행은 빌드와 별도 구간으로 분리하고 본인이 소유한 `/tmp/djc-audio.lock` 안에서 5분 이하로 끝낸다.

## 앱 안 키 전달 검증

디버그 앱의 `--key-routing-selftest`는 `AsyncGuidanceFixtureCapture`로 만든 정상 WAV·손상된 WAV 합성 사본만 연다. 임시 `DJC_HOME`·`DJC_REKORDBOX_DIR`과 `--db <합성 master.db>`를 모두 지정하고, `/tmp/djc-gui.lock`을 잡은 담당자 한 명만 실행한다. 같은 작업 폴더의 Swift 빌드·시험은 먼저 끝낸다. 설치 앱을 종료하거나 바꾸지 않는다.

자가 테스트는 앱을 활성화하지 않고 내부 덱 창의 `makeMain()`·`makeKey()`를 호출해 상태를 확인한 뒤 `NSApp.postEvent`로 그 창 번호의 키를 넣는다. 실제 검색칸의 글자 입력, 곡 목록 탐색·덱 확대, 태그 시트 방향키, AppKit 부착 시트·모달의 글자 입력, 제품 곡 편집 창의 확대를 확인한다. 소리는 재생하지 않으며 CGEvent·화면 좌표 클릭·OS 키 입력은 보내지 않는다. 앞에 있는 외부 앱 PID와 앱 비활성 상태를 시작·끝에서 비교한다.

내부 키 창을 만들 수 없으면 이벤트를 보내기 전에 종료 코드 2로 멈춘다. 이를 통과로 기록하거나 앱 활성화로 우회하지 않는다. 종료 코드 0과 `[키 전달] 결과: N/N 통과`는 앱 안 이벤트의 전달 근거이며, 물리 키보드·IME 조합·OS 포커스 전환의 확인은 별도로 남긴다. 이 Mac의 비활성 앱에서는 내부 key·main 창을 만들지 못해 포커스별 전달이 미검증으로 남았으며, 사용자가 포커스를 내줄 때 확인할 항목은 [#186](https://github.com/fotoner/DJCrate/issues/186)에서 관리한다.

사용자가 입력을 넘겨줄 시간대를 명시적으로 허용한 #186 세션에서는 `--key-routing-selftest --key-routing-mode=active`를 함께 준다. 이 DEBUG 전용 모드는 두 격리 환경 변수와 합성 곡 조건을 확인한 뒤 시험 창을 앞으로 놓고 사용자 클릭을 기다린다. `active=true`, 덱의 `key=true`·`main=true`, 앞 앱이 시험 앱이라는 조건을 먼저 확인하고, 충족하지 못하면 키 이벤트 전송 전에 종료 코드 2로 멈춘다. 모드 인자가 없으면 기존 비활성 검사와 외부 앱 포커스 보존 assertion을 그대로 사용한다. 잘못된 모드·중복 인자·비어 있는 격리 환경은 거부한다.

활성 모드도 키를 `NSApp.postEvent`로 시험 앱 안에만 넣고 소리를 재생하지 않는다. 이 결과는 실제 검색칸·목록·태그 시트·부착 시트·모달·곡 편집 창의 앱 안 전달 확인이며, Codex 컴퓨터 사용의 실제 키 입력이나 물리 키보드·IME 확인을 대신하지 않는다.
활성 모드는 목록 Return·Esc, 태그 글자 입력·Return·Esc, 부착 시트·모달의 Return·Esc도 확인한다. `DJC_HOME/key-routing-captures`에 대상 창 전후 JPEG 32개를 기록하며, 확인 창이 닫힌 뒤에는 같은 앱의 주 창을 캡처한다. 캡처 실패도 최종 결과에 포함한다.
로그에 창 제목을 적고 최대 10분 동안 시험 창 직접 클릭과 실제 활성·키·주 창 상태를 기다린다. 이 대기 동안에는 키를 보내거나 앱을 활성화하지 않는다. 각 키 전송 직전에도 대상 키 창과 앞 앱을 확인해 입력 대상이 바뀌면 종료 코드 2로 중단한다.
정상 합성 곡에는 편집 창을 열 수 있는 DAT·EXT 그리드 분석을 포함한다. 보기 전환은 자가 테스트의 설정 저장 제한과 별개인 `AppStorage`의 태그 보기 키만 직접 바꾼다. 제품 설정 정책·키 전달 정책은 바꾸지 않는다.

실행 전 `defaults export DJCrate <임시 plist>`로 설정을 보관하고, 종료 뒤 실행 전후 값이 다른 키만 원래 값으로 되돌린다. 자가 테스트는 태그 시트 모드를 바꾸고 AppKit은 창 크기를 자동 저장하므로 실패·종료 코드 2에서도 복원한다. 전체 UserDefaults 영역을 가져와 덮지 않는다. 화면 비교는 같은 합성 사본의 `--async-guidance-capture=<임시 폴더>`를 사용하며, 띄운 PID의 창 번호만 `screencapture -x -o -t jpg -l <창 번호>`로 기록한다. 두 인자 모두 디버그 전용이고 값을 받는 인자는 한 덩어리로 쓴다.

메뉴가 보이는 화면(#237 전·후)은 `--issue237-capture=<임시 폴더> --issue237-usb-mount=<합성 디스크 이미지 마운트>`로 찍는다. `LayoutFixtureCapture` 합성 사본(`--db`·`DJC_REKORDBOX_DIR`)과 `UsbSelfTestLibrary`로 내보낸 `DJCDEMO` 이미지(`djc lab usb-image`·`usb-export`)만 읽고 USB 절은 그 볼륨 하나로 바꾼다. 창은 `screencapture -l <창 번호>`로 찍고, 메뉴는 앱 안에서 `NSMenu.popUpContextMenu`로 열어 두고 그 메뉴 창만 찍는다. 비활성 앱은 메뉴를 열지 못해 메뉴가 열려 있는 동안만 잠깐 활성화한다(창은 보고 있는 데스크톱으로 옮겨 다른 창 뒤에 둔다). 앱을 쓰는 중에는 돌리지 않는다.

## 진행 로그·실패 진단

`scripts/check.sh`는 각 단계의 UTC 시작·종료 시각, 경과 초, 종료 코드를 출력한다. 명령 출력은 즉시 화면과 단계별 로그에 함께 쓰고, 출력이 없어도 30초마다 현재 단계와 경과 시간을 알린다. 디버그·테스트 컴파일, 릴리스 빌드, 번역, 전체 테스트 실행·프로파일 수집, 커버리지 보고·목표 검사를 구분한다. SwiftPM의 테스트 실행 명령에는 프로파일 병합·내보내기도 포함되므로 이 단계 전체를 순수 테스트 실행 시간으로 부르지 않는다.

- 로컬 로그: `.build/check-logs/run.XXXXXX/`. `DJC_CHECK_LOG_ROOT`로 상위 폴더를 바꿀 수 있다. 실행마다 새 폴더를 만들어 이전 성공 결과와 섞이지 않게 한다.
- `debug-build.log`, `release-build.log`, `translations.log`, `test.log`, `coverage.log`에 원래 출력을 보존한다. `timings.tsv`에는 단계별 초·종료 코드, `exit-code.txt`에는 전체 종료 코드, `coverage.txt`에는 파일별 집계 입력이 남는다. 실패한 단계 뒤의 로그는 생성되지 않는다.
- 명령이나 `tee`가 실패하면 `pipefail`로 검사가 실패한다. INT·TERM은 각각 130·143으로 끝나며 이 검사에서 시작한 자식 빌드와 진행 알림도 종료한다. 강제 KILL·러너 장애는 종료 요약을 기록할 기회가 없으므로 부분 로그만 남을 수 있다.
- CI는 로그를 캐시 밖인 러너 임시 폴더에 저장하고, `always()` 단계에서 Job summary와 `check-logs-<mode>-<run_id>-<attempt>` artifact를 남긴다(14일 보관). 업로드 대상은 검사·툴체인 텍스트 로그뿐이며 DB·스냅샷·프로파일·실행물은 포함하지 않는다. 취소 시에도 보존을 시도하지만 강제 종료나 러너 유실 시 업로드는 보장되지 않는다.

디버그 앱·CLI·테스트는 `swift build --build-tests --enable-code-coverage`로 함께 빌드한다. 번역 검사에도 같은 계측 옵션을 전달해 설정 전환으로 다시 컴파일하지 않게 하되, 앱과 CLI를 실제 빌드하는 기존 검증은 유지한다. full·coverage에서는 이어서 `swift test --skip-build --enable-code-coverage`로 **전체 테스트를 실행**한다. 별도로 실행하는 `swift scripts/i18n.swift check`·`sync`의 기본 빌드 설정은 바뀌지 않는다. full의 테스트 병렬성·커버리지 목표는 유지한다.

## 테스트 준비 비용

창 크기 변경의 본문 재계산 회귀는 `DJC_LAYOUT_RECOMPUTE_TESTS=1 scripts/check.sh --quick --filter 'LayoutRecomputeTests|LibraryLayoutMetricsTests|DeckLayoutTests|ResizePerfTests'`로 단독 실행한다. 덱·파형이 들어맞는 세로 40단계에서 `LibraryDetail`은 2회 이하, `DeckView`는 5회 이하, 파형 높이 메뉴 문맥(`LibraryWaveformHeightContext`)은 2회 이하를 유지하며, 낮은 창·내용 변경·수동 파형 높이 복원도 검사한다. 시험 창은 `orderBack`으로 열어 활성화하거나 실제 입력을 보내지 않는다.

시간 회귀를 비교할 때는 같은 합성 `UIPerfFixtureCapture` 사본과 디버그 계측 빌드에 `--resize-perf=all --resize-perf-repeats=3 --perf-preview=off --text-scale=1`을 준다. `DJC_DB`·`DJC_REKORDBOX_DIR`·임시 `DJC_HOME`과 `/tmp/djc-heavy.lock`을 사용한다. 전→후→후→전 순서로 실행하고 첫 왕복을 제외한 `RESIZE_SUMMARY`의 단계 중앙값/최댓값·프레임 간격·CPU·본문 횟수와 1·5·15분 load average를 함께 비교한다. `RESIZE_STEP`은 단계별 원본이며, 크기 요청 자체에서도 배치가 일어날 수 있으므로 `layout_flush_ms`만 전체 레이아웃 비용으로 해석하지 않는다. `display_flush_ms`는 표시 처리 호출 비용, `zoom_draw_ms`는 확대 파형 Canvas 실행 비용이다. 디스플레이 링크 콜백 간격은 실제 화면 표시 FPS나 물리 입력 지연이 아니다.

`interval_ms`는 표의 `resize(withOldSuperviewSize:)`·`sizeToFit()`·`layout()`(`table.resize`·`table.columns`·`table.layout`), 덱의 SwiftUI 제안 크기 측정·배치(`swiftui.deck.size`·`swiftui.deck.place`), 전체 파형의 정적 내용·재생선 Canvas(`overview.static.draw`·`overview.playhead.draw`) 호출을 나눈다. 각 항목의 `count`·`median`·`max`·`total`은 호출 횟수와 ms이며 구간끼리 포함될 수 있어 합산하지 않는다. SwiftUI 경계는 같은 제안을 하위 뷰로 넘기는 디버그 측정용 Layout이고, 경계 밖의 지연된 CoreGraph 갱신이나 GPU 표시 시간 전체를 재는 것은 아니다. 표본이 없는 구간은 해당 호출이 관찰되지 않은 것이며 비용이 없다는 뜻은 아니다. 기본 화면과 `--perf-hide=zoom`·`--perf-hide=overview`를 각각 같은 전→후→후→전 순서로 비교하고 `hidden`·부하·설정 복원 결과를 함께 남긴다. 전체 파형은 같은 원본·시간축·크기의 3밴드 경로를 최대 네 개 보관하며, `WaveformBandPath.build` 본문 횟수로 반복 생성이 줄었는지 확인한다.

가짜 오디오·메모리 저장소를 쓰는 `DeckHarness`는 합성 WAV와 임시 폴더만 만든다. DB가 필요한 통합 테스트는 계속 `RekordboxFixture`를 쓴다. 이 픽스처는 암호화 설정을 유지하면서 스키마·초기 행을 한 연결·한 트랜잭션으로 준비하고, 곡·재생 목록의 여러 행도 각각 한 트랜잭션으로 넣는다. 준비 중 실패하면 연결을 닫을 때 미완료 트랜잭션이 취소된다. 픽스처마다 독립된 파일을 쓰며, 실제 쓰기·복원 후 다시 읽는 연결은 공유하거나 캐시하지 않는다.

## 시간 비교 방법과 기준

시험 본문 시간, 전체 CI 시간, 로컬 명령의 wall 시간을 구분해 보고한다. 시험 로그의 `Test run ... passed after ...`는 해당 시험 실행 구간이고, 병렬 suite·test 시간은 겹치므로 합산하지 않는다. `timings.tsv`의 테스트 단계는 SwiftPM 실행·프로파일 수집을 포함한다. 전체 CI 시간은 러너 준비·캐시 복원·검사·캐시 저장을 포함하고, 로컬 wall 시간은 실행한 명령의 시작부터 종료까지다. 서로 다른 범위의 수치를 개선 전후로 비교하지 않는다.

30초는 같은 계측 빌드가 준비된 warm 상태에서 관련 시험에 집중하는 개발 피드백 목표다. cold 빌드·전체 검사·전체 호스티드 CI의 제한 시간이 아니며, 같은 필터·코드·툴체인·환경의 실제 측정 전에는 달성을 보장하지 않는다.

[PR #111 기준 실행](https://github.com/fotoner/DJCrate/actions/runs/36303819883/job/108581536945)은 attempt 2, SHA `7f2395c74307299a222175c1a069dce7a79086f5`, `xcode-27`이었다. API의 해당 attempt/job 시각과 로그로 구분하면 다음과 같다.

| 구간 | 기준 시간 | 해석 |
|---|---:|---|
| job 생성 → 러너 시작 | 9초 | 08:15:08 → 08:15:17 UTC; 재실행 전 대기와 섞지 않음 |
| job 실행 전체 | 18분 10초 | 준비·캐시 복원·검사·캐시 저장 포함 |
| 검사 명령 전체 | 약 17분 20초 | 08:15:42 → 08:33:02 UTC |
| 디버그 빌드 구간 | 약 91초 | 두 번 호출 합계; 첫 호출 시간은 로그에서 분리 불가 |
| 릴리스 빌드 | 약 196초 | Swift가 보고한 빌드 자체는 193.99초 |
| 번역 | 약 32초 | 내부 앱·CLI 빌드 포함 |
| 테스트 단계 | 약 11분 58초 | 컴파일·실행·프로파일 수집 포함, 기존 로그로 각각 분리 불가 |
| 커버리지 보고·목표 검사 | 약 2.4초 | 테스트 명령 종료 뒤 집계 |

기준 결과는 테스트 1,049개, 쓰기 93.0%, 코어 88.9%, 번역 누락·stale 0이다. 이전 커밋 캐시를 복원했지만 디버그·릴리스 빌드 시간이 들었으므로 캐시 복원을 컴파일 생략으로 해석하지 않는다. 기존 스크립트는 디버그 빌드를 두 번 직접 호출하고, 번역 이후 커버리지 설정으로 디버그·테스트를 다시 빌드했다. 변경은 이 중복 호출과 계측 설정 전환을 줄인다. 테스트 본문의 실행 시간은 그대로 남는다.

호스티드 비교는 같은 SHA·러너 이미지·툴체인·검사 범위에서 수동 실행의 `use_cache=false`와 `use_cache=true`를 각각 실행해 기록한다. 꺼진 경우 캐시 복원·저장을 모두 건너뛴다. 켜진 실행도 정확 키 일치, 이전 키 복원, 캐시 없음으로 나누고 실제 캐시 키와 `Build complete`·컴파일 로그를 확인한다. 캐시 저장이 완료된 뒤 다음 실행을 시작해야 `cancel-in-progress`로 앞 실행을 취소하지 않는다.

비교 보고에는 run ID·attempt·SHA, job 생성/시작/종료 시각, 캐시 키·복원/저장 시간, 각 단계 시간, 테스트 수·커버리지·종료 코드를 함께 적는다. 로컬 측정에는 동시 빌드·GUI 검사 등 다른 작업의 부하와 빈/기존 `.build` 여부를 기록한다. 로컬 시간 차이는 호스티드 CI 개선 수치가 아니며, 위 기준 실행은 기존 캐시 복원 사례 한 건이므로 변경 후 cold/warm 측정과 일대일 성능 차이를 단정할 수 없다.

## 러너 선택 (2026-09-26 확인)

`Package.swift`는 macOS 27.0 이상과 Swift tools 6.2 이상을 요구한다. 빌드 SDK뿐 아니라 테스트 실행 OS도 macOS 27 이상이어야 한다.

| 공식 이미지 | 실행 OS·Xcode | 판단 |
|---|---|---|
| `macos-26` / `macos-latest` | macOS 26.6.2, 기본 Xcode 26.6 | macOS 27 테스트 실행 조건을 충족하지 않음 |
| `macos-27` | 공식 라벨 목록에 없음 | 사용하지 않음 |
| `xcode-27` | macOS 27.0, 기본 Xcode 27.0, macOS 27 SDK | 이 워크플로에서 사용 |

근거: [GitHub 표준 호스티드 러너](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [runner-images 라벨 목록](https://github.com/actions/runner-images/blob/ede07f8e48022b2c00dc669c7a9d927c46e32a81/README.md), [macOS 26 이미지](https://github.com/actions/runner-images/blob/ede07f8e48022b2c00dc669c7a9d927c46e32a81/images/macos/macos-26-arm64-Readme.md), [Xcode 27 이미지](https://github.com/actions/runner-images/blob/ede07f8e48022b2c00dc669c7a9d927c46e32a81/images/macos/xcode-27-arm64-Readme.md). [Apple Xcode 요구 사항](https://developer.apple.com/xcode/system-requirements)에 따르면 Xcode 27은 Swift 6.4를 제공하므로 tools 6.2 조건을 충족한다.

`xcode-27`은 **공개 미리보기**다. [공식 공지](https://github.com/actions/runner-images/issues/14404)는 2026-09-16부터 기반 OS를 macOS 27로 변경했다고 명시하며, 안정성·대기열 제약을 안내한다. 워크플로는 `DEVELOPER_DIR`로 Xcode 27.0을 선택하고 실행 시 OS·Xcode·Swift·SDK 버전을 출력한다. 이미지가 바뀌어 OS 또는 SDK가 27 미만이면 빌드 전에 실패한다. 실제 GitHub 실행 여부는 푸시 뒤 확인해야 한다.

## 캐시·데이터·권한

- SwiftPM 의존성과 빌드 결과인 `.build`를 캐시한다. OS·아키텍처·캐시 버전·검사 모드(`test`·`coverage`·`release`·`stress`)·툴체인 지문·`Package.swift`와 `Package.resolved` 해시·커밋으로 키를 만든다. `restore-keys`도 모드를 포함해 일반 테스트·커버리지·릴리스·stress 산출물이 섞이지 않게 한다. 캐시가 있어도 검증은 매번 실행한다. 새 키를 처음 쓰거나 GitHub의 브랜치 접근 범위 안에 같은 모드 캐시가 없으면 캐시 없이 시작한다.
- 테스트는 합성 픽스처만 쓴다. `DJC_HOME`과 `DJC_REKORDBOX_DIR`은 러너 임시 폴더에 두며, 개인 라이브러리·음원·DB·백업을 CI에 올리지 않는다.
- `GITHUB_TOKEN` 권한은 `contents: read`이고 checkout 뒤 인증 정보를 보관하지 않는다. 별도 비밀값은 필요 없다. Actions 버전은 커밋 SHA로 고정한다.
- 포크 PR도 GitHub가 제공하는 임시 VM에서 `pull_request`로 실행한다. self-hosted 러너와 `pull_request_target`은 사용하지 않는다. 러너를 등록할 필요가 없다.

## 워크플로 검사

워크플로를 수정한 뒤 저장소 루트에서 `actionlint`로 검사한다. `python3 scripts/test-check.py`는 합성 명령만으로 빌드·번역·테스트·커버리지·파이프 실패, 빈/미달 커버리지, INT·TERM 취소와 로그 보존을 검사하며 CI에서도 실행한다. 분할 모드·quick·stress의 검사 범위와 실패 전파, 커버리지 목표 유지와 잘못된 인자의 거부도 확인한다. 합성 `HOME` 아래에서 시험이 DJCrate 사용자 폴더·로그 폴더에 쓰면 종료 코드 4로 실패하는지(설치 앱이 켜져 있으면 알림만)도 본다. 실제 Swift 빌드나 라이브러리 접근은 하지 않는다. `.github/actionlint.yaml`은 actionlint 1.7.12가 아직 인식하지 못하는 공개 미리보기 `xcode-27` 라벨만 허용하며, self-hosted 러너를 사용하는 설정은 아니다.

## 푸시 뒤 관리자 확인

1. Actions 설정에서 이 워크플로와 `actions/checkout`, `actions/cache`, `actions/upload-artifact` 실행을 허용한다. 외부 포크 PR은 **모든 외부 기여자의 실행 승인**을 요구하도록 설정하고, 변경 내용을 확인한 뒤 승인한다.
2. `dev` 푸시에서 `test`, PR·`main`·수동 실행에서 `coverage`와 `release`, `run_stress=true`인 수동 실행에서 추가 `stress`가 실행되는지 확인한다. 선택한 stress의 실패·취소·미실행도 필수 집계 체크를 통과시키지 않아야 한다. 실제 검사 러너는 macOS 27·Xcode 27이며, 결과를 합치는 `빌드·테스트·커버리지` job만 Ubuntu에서 실행된다. 포크 PR도 호스티드 러너에서만 실행되는지 확인한다.
3. 첫 실행의 캐시 저장과 다음 실행의 복원, Job summary의 테스트 수·커버리지, README의 `dev` 상태 배지를 확인한다.
4. `dev`·`main` 보호 규칙에 `빌드·테스트·커버리지`를 필수 상태 체크로 추가한다. 워크플로 파일만으로 병합을 차단하지는 못한다.

이 작업은 러너 등록·저장소 설정 변경·푸시를 수행하지 않는다. 미리보기 이미지의 공급이 중단되면 공식 라벨·SDK·실행 OS를 다시 확인한 뒤 러너를 변경한다.
