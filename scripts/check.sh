#!/bin/zsh
# 커밋·합치기 전 확인: 빌드(디버그·릴리스 앱) → 단위 테스트(커버리지) → 영역별 줄 커버리지와 목표.
# 사용: scripts/check.sh            목표(쓰기 80%, 코어 60%) 밑이면 실패
set -euo pipefail
cd "${0:A:h}/.."

echo "▸ 빌드"
swift build 2>&1 | grep -E "error:|warning: .*Sources/" || true
swift build 2>&1 | tail -1
swift build -c release --product DJCrate 2>&1 | tail -1

echo "▸ 단위 테스트"
if ! swift test --enable-code-coverage > .build/check-test.log 2>&1; then
    grep -E "✘|error:" .build/check-test.log | head -30
    echo "테스트 실패(전체 로그: .build/check-test.log)"
    exit 1
fi
grep -E "^✔ Test run" .build/check-test.log | sed 's/^/  /'

echo "▸ 커버리지(줄)"
PROF=.build/out/Products/Debug/codecov/default.profdata
bundles=(.build/out/Products/Debug/*Tests.xctest)
first="${bundles[1]}/Contents/MacOS/$(basename ${bundles[1]} .xctest)"
rest=()
for b in "${bundles[@]:1}"; do rest+=(-object "$b/Contents/MacOS/$(basename $b .xctest)"); done
xcrun llvm-cov report "$first" "${rest[@]}" -instr-profile "$PROF" -ignore-filename-regex='(checkouts|Tests|\.build)/' 2>/dev/null \
    | awk 'NF>=10 && $1 ~ /\.swift$/ {print $1, $8, $9}' > .build/check-coverage.txt
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
    }' .build/check-coverage.txt
echo "▸ 통과"
