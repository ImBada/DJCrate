# 앱 배포

DJCrate는 현재 **Developer ID 서명과 Apple 공증 없이** 배포한다. Apple 계정·인증서·공증용 비밀값은 필요하지 않다. 배포 ZIP에는 ad-hoc 서명한 앱을 넣는다. ad-hoc은 실행 파일과 번들의 무결성을 확인하는 로컬 서명이며 배포자 신원을 보증하지 않는다.

## 설치

현재 자동 배포 대상은 **macOS 27 이상, Apple Silicon(arm64)**이다. Intel용 자동 빌드나 universal 배포는 제공하지 않는다.

1. GitHub Release에서 `DJCrate-X.Y.Z-macOS-arm64.zip`과 같은 이름의 `.zip.sha256`을 같은 폴더에 받는다.
2. 터미널에서 그 폴더로 이동한 뒤 `shasum -a 256 -c DJCrate-X.Y.Z-macOS-arm64.zip.sha256`을 실행한다. `X.Y.Z`는 받은 버전으로 바꾼다. `OK`가 아니면 압축을 풀지 말고 다시 받는다. 이 해시는 전송 무결성 확인용이며 배포자 인증서가 아니다.
3. ZIP을 풀고 `DJCrate.app`을 응용 프로그램 폴더로 옮긴다. 기존 DJCrate가 실행 중이면 먼저 직접 종료한다.
4. 다운로드한 앱은 macOS가 개발자를 확인할 수 없어 차단할 수 있다. 출처와 파일을 확인하고 실행하기로 결정한 경우, 실행을 시도한 뒤 시스템 설정 → 개인정보 보호 및 보안에서 해당 앱의 열기 승인을 확인한다. 자세한 조건은 [Apple의 공식 안내](https://support.apple.com/102445)를 따른다. 관리되는 Mac에서는 승인이 제한될 수 있다.

빌드·설치 스크립트는 Gatekeeper를 끄거나 다운로드 격리 속성을 지우지 않는다. 패키지의 서명 검증 통과는 다른 Mac에서 Gatekeeper가 자동으로 실행을 허용한다는 뜻이 아니다.

## 로컬 빌드와 패키지

macOS 27 SDK를 포함한 Xcode와 Swift 6.2 이상이 필요하다. 현재 CI 도구와 러너 조건은 [CI 문서](ci.md)를 따른다.

```sh
scripts/build-app.sh                         # 기존 로컬 앱 빌드
scripts/build-app.sh --install               # 기존 로컬 설치
scripts/build-app.sh --version 0.0.0 --package # 발행하지 않는 시험용 ZIP
scripts/build-app.sh --tag v0.0.0 --package   # 태그 문자열을 직접 전달
```

`0.0.0`은 예시용 시험 버전이며 출시 버전을 정하지 않는다. `--version`은 `X.Y.Z`, `--tag`는 `vX.Y.Z`만 받는다. 각 숫자의 앞자리 0, 접미사, 중복 버전 옵션, 알 수 없는 옵션은 빌드 전에 거절한다. 인자가 없으면 현재 커밋의 정확한 `vX.Y.Z` 태그를 사용하고, 태그도 없으면 기존 로컬 빌드 버전 `0.1`을 유지한다. `--package`는 명시적 버전 또는 현재 커밋의 태그가 있어야 한다. `CFBundleVersion`은 전체 Git 이력의 커밋 수다.

`--package`는 항상 `codesign --sign - --timestamp=none`으로 프레임워크와 앱을 서명한다. 키체인을 검색하지 않고 `DJC_SIGN_IDENTITY`도 사용하지 않는다. 일반 빌드와 `--install`은 기존 `DJC_SIGN_IDENTITY` → Apple Development 인증서 자동 탐색 → ad-hoc 순서를 유지한다. `--package`와 `--install`은 함께 지정할 수 없다.

결과물은 `dist/DJCrate.app`, `dist/DJCrate-X.Y.Z-macOS-<아키텍처>.zip`, 같은 이름의 `.zip.sha256`이다. 아키텍처는 실제 실행 파일에서 읽는다. ZIP은 `DJCrate.app`을 최상위에 담고, 앱에는 실행 파일·SQLCipher 프레임워크·아이콘·한국어/영어/일본어 리소스·`LICENSE`·`THIRD_PARTY_NOTICES.md`가 들어간다. 개발용 데이터나 라이브러리 사본은 넣지 않는다.

Apple Silicon에서는 실행 코드 서명이 필요하며 ad-hoc도 이 조건을 충족한다. 기존 스크립트는 `install_name_tool`로 실행 파일을 바꾸므로 마지막에 다시 서명하고 `codesign --verify --deep --strict`로 검증한다. 이는 Developer ID 서명·공증과 별개다. 근거: [Apple Silicon 실행 코드 서명 요구](https://developer.apple.com/documentation/macos-release-notes/macos-big-sur-11_0_1-universal-apps-release-notes/), [ad-hoc 서명의 의미](https://developer.apple.com/documentation/security/seccodesignatureflags/adhoc?language=objc).

## 태그에서 Release까지

출시할 버전과 커밋은 관리자가 별도로 결정한다. `.github/workflows/release.yml`은 `v*.*.*` 태그 푸시에 반응하고, 정확한 `vX.Y.Z` 형식인지 다시 검사한다. 워크플로를 추가하는 것만으로 태그나 Release를 만들지는 않는다.

1. 전체 Git 이력을 받아 태그의 커밋으로 빌드한다. checkout 인증 정보는 남기지 않는다.
2. macOS·SDK 27 이상과 arm64를 확인하고 `scripts/check.sh`를 실행한다.
3. 태그를 `build-app.sh --tag "$RELEASE_TAG" --package`에 전달한다.
4. ZIP의 SHA-256, 압축 해제한 번들의 서명·버전·아키텍처·실행 파일 일치·라이선스 파일을 검사한다.
5. 기존 태그를 `gh release create --verify-tag`로 확인하고 ZIP과 SHA-256을 Release에 올린다. 서명·공증 부재와 설치 안내를 먼저 쓰고 GitHub 자동 생성 변경 내역을 덧붙인다.

발행 단계는 GitHub가 제공하는 `GITHUB_TOKEN`의 `contents: write` 권한만 사용한다. 별도 비밀값을 등록하지 않는다. 같은 태그의 실행은 직렬화하며 기존 Release를 덮어쓰거나 태그를 새로 만들지 않는다. 재실행 때 이미 Release가 있으면 실패하므로 관리자가 기존 결과와 실패 단계를 확인해야 한다. 근거: [GitHub 토큰 권한](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token), [gh release create](https://cli.github.com/manual/gh_release_create).

로컬에서는 `zsh -n scripts/build-app.sh`, `actionlint .github/workflows/release.yml`, 시험용 패키지의 해시·압축 해제·서명·Info.plist 검사를 수행한다. 실제 태그 실행·Release 업로드와 다운로드한 앱의 다른 Mac 설치·최초 실행은 별도의 배포 검증이다.
