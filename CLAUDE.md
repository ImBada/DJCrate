@AGENTS.md

# Claude Code

- rekordbox 쓰기 코드(`Sources/RekordboxKit/` 등)를 열면 `.claude/rules/rekordbox-write.md`가 함께 로드된다. 그 규칙을 따른다.
- 웹·다른 저장소 조사처럼 파일을 많이 읽는 일은 서브에이전트로 돌리고 결론만 가져온다.
- 앱 자가 테스트는 `timeout 60~300`을 걸어 포그라운드로 돌리고, 출력은 파일로 받아(`> 로그 2>&1`) 필요한 줄만 grep한다.
- 완료 보고는 바꾼 것 → 확인한 것(실행한 명령과 결과 수치) → 남은 것·사용자에게 물을 것 순서로, 짧게.
