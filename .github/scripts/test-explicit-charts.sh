#!/usr/bin/env bash

# Copyright The Helm Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

action_script="$(git rev-parse --show-toplevel)/cr.sh"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export REAL_GIT
REAL_GIT=$(command -v git)
export FETCH_TRACE="$test_root/fetches"
export CR_COMMAND_TRACE="$test_root/commands"
export CR_PACKAGE_TRACE="$test_root/packages"
export RUNNER_TOOL_CACHE="$test_root/cache"
install_dir="$RUNNER_TOOL_CACHE/cr"
mkdir -p "$test_root/bin" "$install_dir" "$test_root/repo"

cat > "$test_root/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == fetch ]]; then
  echo fetch >> "$FETCH_TRACE"
  exit 0
fi
exec "$REAL_GIT" "$@"
EOF

cat > "$install_dir/cr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$1" >> "$CR_COMMAND_TRACE"
if [[ "$1" == package ]]; then
  printf '%s\n' "$2" >> "$CR_PACKAGE_TRACE"
  fixture_dir=$(mktemp -d)
  mkdir -p "$fixture_dir/fixture"
  cp "$2/Chart.yaml" "$fixture_dir/fixture/Chart.yaml"
  tar -czf "$4/fixture-0.1.0.tgz" -C "$fixture_dir" fixture
  rm -rf "$fixture_dir"
elif [[ "$1" == upload && "${CR_FAIL_UPLOAD:-false}" == true ]]; then
  exit 42
fi
EOF
chmod +x "$test_root/bin/git" "$install_dir/cr"

cd "$test_root/repo"
git init -q -b main
git config user.name test
git config user.email test@example.invalid
git config commit.gpgsign false
mkdir -p charts/one 'charts/with space' generated/ignored
for chart_dir in . charts/one 'charts/with space' generated/ignored; do
  printf 'apiVersion: v2\nname: fixture\nversion: 0.1.0\n' > "$chart_dir/Chart.yaml"
done
printf 'generated/\n' > .gitignore
git add .gitignore Chart.yaml charts
git commit -qm 'Unchanged chart fixtures'
export PATH="$test_root/bin:$PATH"

reset_trace() {
  : > "$FETCH_TRACE"
  : > "$CR_COMMAND_TRACE"
  : > "$CR_PACKAGE_TRACE"
}

run_action() {
  CR_TOKEN=fake bash "$action_script" --owner test --repo fixtures --install-dir "$install_dir" "$@"
}

reset_trace
run_action
test -s "$FETCH_TRACE"
test ! -s "$CR_COMMAND_TRACE"
test "$(cat changed_charts.txt)" = 'changed_charts='
echo 'PASS: automatic discovery stays the default and detects no changes.'

reset_trace
run_action --charts $'charts/one\r\ncharts/with space\n./charts/one/\ngenerated/ignored\n\n' --charts-dir unused --match-tags 'unmatched-*'
test ! -s "$FETCH_TRACE"
printf 'charts/one\ncharts/with space\ngenerated/ignored\n' > "$test_root/expected-packages"
diff -u "$test_root/expected-packages" "$CR_PACKAGE_TRACE"
test "$(cat changed_charts.txt)" = 'changed_charts=charts/one,charts/with space,generated/ignored'
test "$(cat chart_version.txt)" = 'chart_version=fixture-0.1.0,fixture-0.1.0,fixture-0.1.0'
echo 'PASS: explicit selection bypasses tags/diffs and supports spaces, CRLF, ignored charts, and deduplication.'

reset_trace
run_action --charts .
test ! -s "$FETCH_TRACE"
test "$(cat "$CR_PACKAGE_TRACE")" = .
test "$(cat changed_charts.txt)" = 'changed_charts=.'
echo 'PASS: an explicit chart at the repository root is supported.'

reset_trace
touch .cr-release-packages/preserve.tgz
if run_action --charts $'charts/one\nmissing-chart' > "$test_root/invalid.log" 2>&1; then
  echo 'Expected an invalid chart to fail' >&2
  exit 1
fi
grep -F 'must be a directory containing Chart.yaml' "$test_root/invalid.log"
test ! -s "$CR_COMMAND_TRACE"
test -f .cr-release-packages/preserve.tgz
if run_action --charts $' \n\r\n' > "$test_root/blank.log" 2>&1; then
  echo 'Expected a blank selection to fail' >&2
  exit 1
fi
grep -F 'must contain at least one chart directory' "$test_root/blank.log"
test ! -s "$CR_COMMAND_TRACE"
echo 'PASS: the full selection is validated before packaging or clearing existing packages.'

reset_trace
if run_action --charts charts/one --skip-packaging true > "$test_root/conflict.log" 2>&1; then
  echo 'Expected conflicting packaging modes to fail' >&2
  exit 1
fi
grep -F 'cannot be combined' "$test_root/conflict.log"
test ! -s "$CR_COMMAND_TRACE"
test -f .cr-release-packages/preserve.tgz
echo 'PASS: conflicting packaging modes fail without running cr.'

reset_trace
if CR_FAIL_UPLOAD=true run_action --charts charts/one; then
  echo 'Expected the upload failure to propagate' >&2
  exit 1
fi
test "$(tail -1 "$CR_COMMAND_TRACE")" = upload
echo 'PASS: release failures still stop processing before index updates.'
