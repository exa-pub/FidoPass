#!/usr/bin/env bash
# This group is mandatory in CI: a missing helper, missing tests or any skip is a failure.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build_test_authenticator.sh
CARGO_TARGET_DIR="$PWD/.build/test-authenticator/target" cargo +1.94.1 test --locked \
  --manifest-path tools/test-authenticator/Cargo.toml
export FIDOPASS_TEST_AUTHENTICATOR="$PWD/.build/test-authenticator/target/debug/fidopass-test-authenticator"
export FIDOPASS_REQUIRE_KEY_TESTS=1
log="$(mktemp -t fidopass-key-tests)"
trap 'rm -f "$log"' EXIT
swift test "$@" --filter KeyTransportIntegrationTests 2>&1 | tee "$log"
python3 - "$log" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
# XCTest's exact wording varies across Swift versions; require actual case completions.
passed = re.findall(r"Test Case .*KeyTransportIntegrationTests.* passed", text)
if not passed or re.search(r'KeyTransportIntegrationTests.*(?:skipped|failed)', text):
    sys.exit('Required OpenSK tests did not all execute successfully')
print(f'Required OpenSK cases completed: {len(passed)}')
PY
