#!/bin/zsh
# 커밋·합치기 전 확인: 디버그·릴리스 앱, 번역, 전체 테스트, 쓰기 80%·코어 60% 커버리지.
set -euo pipefail
cd "${0:A:h}/.."

# 실행마다 다른 폴더를 써서 이전 실패·취소 로그와 섞이지 않게 한다.
log_root=${DJC_CHECK_LOG_ROOT:-.build/check-logs}
mkdir -p "$log_root"
log_dir=$(mktemp -d "$log_root/run.XXXXXX")
printf '단계\t초\t종료코드\n' > "$log_dir/timings.tsv"
integer check_started=$SECONDS stage_started=0
stage_name=""
stage_pid=""
pulse_pid=""

# 이 검사에서 시작한 자식만 정리한다. 부모 셸만 취소되어도 빌드가 남지 않아야 한다.
stop_tree() {
    local pid=$1 child
    for child in ${(f)"$(pgrep -P "$pid" || true)"}; do
        [[ -n "$child" ]] && stop_tree "$child"
    done
    kill -TERM "$pid" 2>/dev/null || true
}

finish() {
    local code=$1
    trap '' INT TERM
    if [[ -n "$stage_pid" ]]; then
        stop_tree "$stage_pid"
        wait "$stage_pid" 2>/dev/null || true
        printf '%s\t%d\t%d\n' "$stage_name" "$((SECONDS - stage_started))" "$code" >> "$log_dir/timings.tsv"
        echo "▸ 종료: $stage_name ($((SECONDS - stage_started))초, 종료코드 $code)"
    fi
    if [[ -n "$pulse_pid" ]]; then
        stop_tree "$pulse_pid"
        wait "$pulse_pid" 2>/dev/null || true
    fi
    echo "▸ 전체 종료: $((SECONDS - check_started))초, 종료코드 $code (로그: $log_dir)"
    print -r -- "$code" > "$log_dir/exit-code.txt"
}
trap 'finish $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_stage() {
    local name=$1 file=$2 code
    shift 2
    stage_name=$name
    stage_started=$SECONDS
    echo "▸ 시작: $name ($(date -u +%Y-%m-%dT%H:%M:%SZ), 로그: $log_dir/$file.log)"
    # 비동기 wait는 셸에 온 취소 신호를 즉시 처리한다. pipefail로 명령·tee 실패를 보존한다.
    ( "$@" 2>&1 | tee "$log_dir/$file.log" ) &
    stage_pid=$!
    (
        while sleep 30; do
            echo "▸ 진행: $name ($((SECONDS - stage_started))초)"
        done
    ) &
    pulse_pid=$!
    if wait "$stage_pid"; then code=0; else code=$?; fi
    stage_pid=""
    stop_tree "$pulse_pid"
    wait "$pulse_pid" 2>/dev/null || true
    pulse_pid=""
    printf '%s\t%d\t%d\n' "$name" "$((SECONDS - stage_started))" "$code" >> "$log_dir/timings.tsv"
    echo "▸ 종료: $name ($((SECONDS - stage_started))초, 종료코드 $code, $(date -u +%Y-%m-%dT%H:%M:%SZ))"
    # zsh의 함수 실패에 따른 errexit은 EXIT 트랩을 건너뛸 수 있어 명시적으로 끝낸다.
    if (( code != 0 )); then exit "$code"; fi
}

coverage() {
PROF=.build/out/Products/Debug/codecov/default.profdata
bundles=(.build/out/Products/Debug/*Tests.xctest)
first="${bundles[1]}/Contents/MacOS/$(basename ${bundles[1]} .xctest)"
rest=()
for b in "${bundles[@]:1}"; do rest+=(-object "$b/Contents/MacOS/$(basename $b .xctest)"); done
xcrun llvm-cov report "$first" "${rest[@]}" -instr-profile "$PROF" -ignore-filename-regex='(checkouts|Tests|\.build)/' \
    | awk 'NF>=10 && $1 ~ /\.swift$/ {print $1, $8, $9}' > "$log_dir/coverage.txt"
awk '
    function add(group, lines, missed) { total[group] += lines; miss[group] += missed }
    {
        if ($1 ~ /^RekordboxKit\/(RekordboxWriter|RekordboxGridWriter|RekordboxCompatibility|RekordboxTrackWriter|RekordboxTrackAdd)/) add("쓰기", $2, $3)
        if ($1 ~ /^(DJCDomain|RekordboxKit|DJCStorage|DJCAnalysis)\//) add("코어", $2, $3)
        if ($1 ~ /^DJCrate\//) add("앱", $2, $3)
    }
    END {
        target["쓰기"] = 80; target["코어"] = 60; target["앱"] = 0
        failed = 0
        n = split("쓰기 코어 앱", order, " ")
        for (i = 1; i <= n; i++) {
            g = order[i]
            pct = total[g] ? 100 * (total[g] - miss[g]) / total[g] : 0
            mark = (pct >= target[g]) ? "✔" : "✘"
            if (pct < target[g]) failed = 1
            printf "  %s %-4s %5.1f%%  (%d줄 중 %d줄, 목표 %d%%)\n", mark, g, pct, total[g], total[g] - miss[g], target[g]
        }
        exit failed
    }' "$log_dir/coverage.txt"
}

# 디버그 앱·CLI·테스트를 같은 계측 설정으로 한 번 빌드해 설정 전환에 따른 재컴파일을 줄인다.
run_stage "디버그·테스트 빌드(커버리지 계측)" debug-build swift build --build-tests --enable-code-coverage
run_stage "릴리스 앱 빌드" release-build swift build -c release --product DJCrate
run_stage "번역(en·ja 누락·안 쓰는 문구·자리표시자)" translations swift scripts/i18n.swift check --enable-code-coverage
run_stage "전체 테스트 실행·프로파일 수집(빌드 생략)" test swift test --skip-build --enable-code-coverage
run_stage "커버리지 보고·목표 검사" coverage coverage
echo "▸ 통과"
