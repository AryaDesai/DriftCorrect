#!/bin/bash
# Build each part separately, run the tests, and write build/report.txt.
# Send build/report.txt back if anything fails.
set -u
cd "$(dirname "$0")/.."
mkdir -p build
REPORT=build/report.txt
{
  echo "== $(date) =="
  sw_vers 2>/dev/null
  swift --version 2>&1 | head -2
  echo "Developer dir: $(xcode-select -p 2>/dev/null)"
  sysctl -n machdep.cpu.brand_string 2>/dev/null
} > "$REPORT"

# Errors without colour codes, each error once, with 3 lines of context.
summarize() {
  sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' "$1" \
    | grep -E "^/.*: error:" -A3 \
    | awk '/: error:/ { if (seen[$0]++) { skip=3; next } } skip>0 { skip--; next } { print }' \
    | head -400
}

FAILED=0
for product in dc DriftCorrectApp; do
  echo "Building $product (release)…"
  swift build -c release --product "$product" > "build/build_$product.log" 2>&1
  if [ $? -ne 0 ]; then
    echo "== BUILD FAILED: $product ==" >> "$REPORT"
    summarize "build/build_$product.log" >> "$REPORT"
    FAILED=1
  else
    echo "== BUILD OK: $product ==" >> "$REPORT"
  fi
done

echo "Running tests…"
swift test > build/test.log 2>&1
if [ $? -ne 0 ]; then
  echo "== TESTS FAILED ==" >> "$REPORT"
  summarize build/test.log >> "$REPORT"
  sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' build/test.log | grep -E "failed|XCTAssert" | head -200 >> "$REPORT"
  FAILED=1
else
  echo "== TESTS OK ==" >> "$REPORT"
fi
grep -E "Gaussian .* differ|Executed" build/test.log >> "$REPORT"

BIN="$(swift build -c release --show-bin-path)"
if [ -x "$BIN/dc" ]; then
  echo "Benchmark…"
  "$BIN/dc" bench >> "$REPORT" 2>&1 || echo "bench failed" >> "$REPORT"
fi
echo "Done. Report: $REPORT"
exit $FAILED
