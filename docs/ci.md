# 빌드·테스트 CI

`.github/workflows/check.yml`은 `dev`·`main` 푸시와 모든 PR에서 `scripts/check.sh`를 실행한다. 디버그 빌드·릴리스 앱 빌드·단위 테스트·줄 커버리지 목표(쓰기 80%, 코어 60%)를 검사하고, 테스트 수와 커버리지를 Actions의 Job summary에 남긴다. 실패한 단계가 있으면 워크플로도 실패한다. 오디오·UI 앱 자가 테스트, 앱 설치·서명·배포는 실행하지 않는다.

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

- SwiftPM 의존성과 빌드 결과인 `.build`를 캐시한다. OS·아키텍처·툴체인 지문·`Package.swift`와 `Package.resolved` 해시·커밋으로 키를 만들고, 같은 환경·의존성의 이전 커밋 캐시를 재사용한다. 캐시가 있어도 검증은 매번 실행한다.
- 테스트는 합성 픽스처만 쓴다. `DJC_HOME`과 `DJC_REKORDBOX_DIR`은 러너 임시 폴더에 두며, 개인 라이브러리·음원·DB·백업을 CI에 올리지 않는다.
- `GITHUB_TOKEN` 권한은 `contents: read`이고 checkout 뒤 인증 정보를 보관하지 않는다. 별도 비밀값은 필요 없다. Actions 버전은 커밋 SHA로 고정한다.
- 포크 PR도 GitHub가 제공하는 임시 VM에서 `pull_request`로 실행한다. self-hosted 러너와 `pull_request_target`은 사용하지 않는다. 러너를 등록할 필요가 없다.

## 푸시 뒤 관리자 확인

1. Actions 설정에서 이 워크플로와 `actions/checkout`, `actions/cache` 실행을 허용한다. 외부 포크 PR은 **모든 외부 기여자의 실행 승인**을 요구하도록 설정하고, 변경 내용을 확인한 뒤 승인한다.
2. `dev`·`main` 푸시와 PR에서 `빌드·테스트·커버리지` 체크가 시작되는지, 실제 러너가 macOS 27·Xcode 27인지 확인한다. 포크 PR도 호스티드 러너에서만 실행되는지 확인한다.
3. 첫 실행의 캐시 저장과 다음 실행의 복원, Job summary의 테스트 수·커버리지, README의 `dev` 상태 배지를 확인한다.
4. `dev`·`main` 보호 규칙에 `빌드·테스트·커버리지`를 필수 상태 체크로 추가한다. 워크플로 파일만으로 병합을 차단하지는 못한다.

이 작업은 러너 등록·저장소 설정 변경·푸시를 수행하지 않는다. 미리보기 이미지의 공급이 중단되면 공식 라벨·SDK·실행 OS를 다시 확인한 뒤 러너를 변경한다.
