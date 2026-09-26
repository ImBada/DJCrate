# 기여 안내

macOS 27 이상과 Swift 6.2 툴체인(Xcode)이 필요하다.

```bash
swift build             # 디버그 빌드
scripts/build-app.sh    # dist/DJCrate.app 만들기
scripts/check.sh        # 빌드·단위 테스트·커버리지 목표 확인
```

rekordbox 쓰기 시험은 사본으로만 한다. `DJC_REKORDBOX_DIR=<사본 폴더>`와 `DJC_HOME=$(mktemp -d)`를 지정하고, 사본의 `share/PIONEER/USBANLZ`도 심볼릭 링크가 아닌 실제 복사본을 쓴다. 앱 자가 테스트에도 임시 `DJC_HOME`을 지정한다. 라이브 DB·분석 파일·음원에는 쓰지 않는다.

이슈를 만들거나 고를 때는 [이슈 관리 규칙](docs/issues.md)을 따른다. 브랜치·커밋은 [AGENTS.md의 저장소 규칙](AGENTS.md#저장소-규칙)을 따르고, `dev`를 대상으로 PR을 연다. PR에는 변경 내용과 실행한 확인 명령·결과를 적고, rekordbox 쓰기 경로를 바꿨다면 사본 자가 테스트 결과도 적는다.

rekordbox 규칙 확인 방법, 외부 코드·문서와 제3자 고지, 내보내는 파일의 칸 단위 작성은 [AGENTS.md의 개발 규칙](AGENTS.md#가장-중요한-규칙-rekordbox-라이브러리를-절대-깨뜨리지-않는다)을 따른다.
