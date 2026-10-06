# 기여 안내

macOS 27 이상과 Swift 6.2 툴체인(Xcode)이 필요하다.

```bash
swift build             # 디버그 빌드
scripts/build-app.sh    # dist/DJCrate.app 만들기
scripts/check.sh        # 빌드·번역 누락·단위 테스트·커버리지 목표 확인
```

화면 문구를 더하거나 고치면 `swift scripts/i18n.swift sync` 뒤 영어·일본어 번역을 채운다([다국어 규칙](docs/i18n.md)). 영어 번역이 빠지면 영어·그 밖의 언어 사용자에게 한국어가 보이므로 `check.sh`가 막는다.

rekordbox 쓰기 시험은 사본으로만 한다. `DJC_REKORDBOX_DIR=<사본 폴더>`와 `DJC_HOME=$(mktemp -d)`를 지정하고, 사본의 `share/PIONEER/USBANLZ`도 심볼릭 링크가 아닌 실제 복사본을 쓴다. 앱 자가 테스트에도 임시 `DJC_HOME`을 지정한다. 라이브 DB·분석 파일·음원에는 쓰지 않는다.

이슈를 만들거나 고를 때는 [이슈 관리 규칙](docs/issues.md)을 따른다. 브랜치·커밋은 [AGENTS.md의 저장소 규칙](AGENTS.md#저장소-규칙)을 따르고, `dev`를 대상으로 PR을 연다. PR에는 변경 내용과 실행한 확인 명령·결과를 적고, rekordbox 쓰기 경로를 바꿨다면 사본 자가 테스트 결과도 적는다.

rekordbox 규칙 확인 방법, 외부 코드·문서와 제3자 고지, 내보내는 파일의 칸 단위 작성은 [AGENTS.md의 개발 규칙](AGENTS.md#가장-중요한-규칙-rekordbox-라이브러리를-절대-깨뜨리지-않는다)을 따른다.

앱 아이콘은 Xcode 27의 `actool`로 `Assets/AppIcon.icon`을 컴파일한다. 전경 SVG를 바꿀 때는 `swift scripts/make-icon.swift`로 다시 만들고, Icon Composer에서 배경·레이어 순서와 기본·다크·모노 외관을 확인한다. 모서리·반사 효과는 시스템이 입히므로 원본에 그리지 않는다.

## 데이터 폴더와 환경 변수

DJCrate 데이터는 `~/Library/Application Support/DJCrate/`에 있다.

- 초안: `cue-drafts/`, `grid-drafts/`, `gain-drafts.json`, `tag-drafts/`
- 추가한 곡: `staged.json`
- 스냅샷: `snapshots/`, 백업: `rekordbox-backups/`
- 캐시: `analysis/`, `waveforms/`, `loudness.json`

스냅샷·백업·DB 사본에는 rekordbox 클라우드 토큰이 들어 있다. 커밋·이슈·로그에 넣지 않는다.

| 환경 변수 | 하는 일 |
|---|---|
| `DJC_HOME` | 데이터 폴더를 바꾼다(시험에서는 항상 임시 폴더) |
| `DJC_REKORDBOX_DIR` | rekordbox 폴더 대신 쓸 사본 폴더 |
| `DJC_DB` | 앱이 열 스냅샷(앱 인자 `--db <스냅샷>`과 같음) |
| `DJC_IDLE_SECONDS` | 재생을 멈춘 뒤 오디오 엔진을 끄기까지의 초 |

## 개발용 명령

`djc`의 읽기·초안 명령은 [docs/cli.md](docs/cli.md)에 있다. 아래는 규칙 확인과 쓰기 시험에 쓰는 명령이다. 모두 사본(`--db <사본.db>`)을 기본으로 한다.

```bash
.build/debug/djc cue-write --db <사본.db> [--dry-run]                          # 큐 초안을 사본에 써 보기
.build/debug/djc track-add --db <사본.db> --share <폴더> --analyze <음원…>     # 곡 넣기(분석까지)
.build/debug/djc track-delete --db <사본.db> --share <폴더> <ContentID…>       # 곡 빼기
.build/debug/djc rekordbox-restore --backup <폴더> --db <사본.db>              # 백업으로 되돌리기
.build/debug/djc lab                                                           # 실험 명령 목록(sql·db-diff·loop-repro 등)
```

소리·실제 화면·반영 전 과정은 디버그 빌드의 앱 자가 테스트로 확인한다. 인자와 조건은 [AGENTS.md의 검증 표](AGENTS.md#검증-작업이-끝났다고-말하기-전에)에 있다.

## 메뉴·단축키 손 확인

디버그 앱을 `DJC_HOME=<임시 폴더> DJC_REKORDBOX_DIR=<사본 폴더> DJC_DB=<사본 DB> .build/debug/DJCrate`로 연다(사본은 분석 파일까지 실제로 복사한 것).

1. 파일·보기·rekordbox·덱·도움말 메뉴 항목, 조합 단축키, 곡 선택·반영 대기·쓰기 중의 활성 상태를 본다. 덱 메뉴의 수식키 없는 키는 안내이고 실제 입력은 KeyRouter가 받는다.
2. 사이드바를 숨긴 채 ⌘⇧E로 반영 확인 창을 열고 취소한다. ⌘I와 ⌃⌘I가 같은 태그 편집기를 여닫는지 본다.
3. 설정에서 재생·핫큐 키를 바꾸고 덱 메뉴·단축키 창 안내가 따라가는지, 새 키가 한 번만 실행되는지, 검색창·설정·단축키 창에서는 덱 키가 끼어들지 않는지 본 뒤 원래 키로 돌린다.
4. 보기 › 툴바 사용자화와 도움말 › DJCrate 단축키를 라이트·다크에서 연다.
