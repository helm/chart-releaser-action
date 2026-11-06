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
export HOME="$test_root/home"
mkdir -p "$HOME"
export REAL_GIT
REAL_GIT=$(command -v git)
export FETCH_TRACE="$test_root/fetches"
export CR_COMMAND_TRACE="$test_root/commands"
export CR_PACKAGE_TRACE="$test_root/packages"
export CR_TEST_EXPECTED_PACKAGE_PATH=.cr-release-packages
export RUNNER_TOOL_CACHE="$test_root/cache"
install_dir="$RUNNER_TOOL_CACHE/cr"
mkdir -p "$test_root/bin" "$install_dir" "$test_root/repo"

cat > "$test_root/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == fetch && " $* " == *" --tags "* ]]; then
  echo fetch >> "$FETCH_TRACE"
  exit 0
fi
exec "$REAL_GIT" "$@"
EOF

cat > "$install_dir/cr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command="$1"
shift
echo "$command" >> "$CR_COMMAND_TRACE"
if [[ "$command" == package ]]; then
  chart="$1"
  shift
  package_path=
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --package-path)
      package_path="$2"
      shift 2
      ;;
    *)
      shift
      ;;
    esac
  done
  version=$(sed -n 's/^version: //p' "$chart/Chart.yaml")
  printf '%s\n' "$chart" >> "$CR_PACKAGE_TRACE"
  fixture_dir=$(mktemp -d)
  mkdir -p "$fixture_dir/fixture"
  cp "$chart/Chart.yaml" "$fixture_dir/fixture/Chart.yaml"
  tar -czf "$package_path/fixture-$version.tgz" -C "$fixture_dir" fixture
  rm -rf "$fixture_dir"
elif [[ "$command" == upload || "$command" == index || "$command" == push ]]; then
  package_path=
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --package-path)
      package_path="$2"
      shift 2
      ;;
    *)
      shift
      ;;
    esac
  done
  if [[ "$package_path" != "$CR_TEST_EXPECTED_PACKAGE_PATH" ]]; then
    echo "expected package path '$CR_TEST_EXPECTED_PACKAGE_PATH' for $command, got '$package_path'" >&2
    exit 1
  fi
  if [[ "$command" == upload && -n "${CR_TEST_EXPECT_PAGES_BRANCH:-}" ]] &&
    ! git show-ref --quiet --verify "refs/remotes/origin/$CR_TEST_EXPECT_PAGES_BRANCH"; then
    echo "expected publishing branch '$CR_TEST_EXPECT_PAGES_BRANCH' before upload" >&2
    exit 1
  fi
  if [[ "$command" == upload && "${CR_FAIL_UPLOAD:-false}" == true ]]; then
    exit 42
  fi
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
git tag initial-charts
git init -q --bare "$test_root/origin.git"
git remote add origin "$test_root/origin.git"
git push -q origin HEAD:refs/heads/main
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
test "$(cat releases.txt)" = 'releases=[]'
if git ls-remote --exit-code --heads origin refs/heads/gh-pages >/dev/null; then
  echo 'The publishing branch should not be created when no charts changed' >&2
  exit 1
else
  test "$?" -eq 2
fi
echo 'PASS: automatic discovery stays the default and detects no changes.'

mkdir -p charts/one/docs
printf 'Chart documentation\n' > charts/one/README.md
printf 'README.md\n' > charts/one/.helmignore
printf 'Release notes\n' > charts/one/docs/notes.md
git add charts/one/README.md charts/one/.helmignore charts/one/docs/notes.md
git commit -qm 'Add chart documentation'

reset_trace
run_action
test "$(cat "$CR_PACKAGE_TRACE")" = charts/one
echo 'PASS: documentation changes still trigger packaging when no ignore paths are configured.'

git tag before-ignored-chart-files
printf 'Updated chart documentation\n' > charts/one/README.md
printf 'Updated ignore rules\n' > charts/one/.helmignore
printf 'Updated release notes\n' > charts/one/docs/notes.md
git add charts/one/README.md charts/one/.helmignore charts/one/docs/notes.md
git commit -qm 'Update ignored chart files'

reset_trace
run_action --ignore-paths $'README.md\r\n.helmignore\n \ndocs/*\n' > "$test_root/ignored-paths.log" 2>&1 || {
  cat "$test_root/ignored-paths.log" >&2
  exit 1
}
test ! -s "$CR_PACKAGE_TRACE"
test "$(cat changed_charts.txt)" = 'changed_charts='
echo 'PASS: configured chart-relative glob patterns exclude matching file changes.'

printf 'apiVersion: v2\nname: fixture\nversion: 0.1.1\n' > charts/one/Chart.yaml
git add charts/one/Chart.yaml
git commit -qm 'Bump chart version'

reset_trace
run_action --ignore-paths $'README.md\n.helmignore\ndocs/*'
test "$(cat "$CR_PACKAGE_TRACE")" = charts/one
test "$(cat changed_charts.txt)" = 'changed_charts=charts/one'
echo 'PASS: non-ignored changes still trigger packaging alongside ignored path patterns.'

reset_trace
run_action --charts charts/one --ignore-paths README.md
test "$(cat "$CR_PACKAGE_TRACE")" = charts/one
echo 'PASS: explicit chart selection is not affected by ignore paths.'
echo 'PASS: automatic discovery stays the default and detects no changes.'

mkdir -p root-chart-one root-chart-two
for chart_dir in root-chart-one root-chart-two; do
  printf 'apiVersion: v2\nname: fixture\nversion: 0.1.0\n' > "$chart_dir/Chart.yaml"
done
git add root-chart-one root-chart-two
git commit -qm 'Add charts at repository root'

reset_trace
run_action --charts-dir .
printf 'root-chart-one\nroot-chart-two\n' > "$test_root/expected-packages"
diff -u "$test_root/expected-packages" "$CR_PACKAGE_TRACE"
test "$(cat changed_charts.txt)" = 'changed_charts=root-chart-one,root-chart-two'
test "$(sed 's/^releases=//' releases.txt | jq -c '.[] | {chart, version, tag}' | paste -sd ',' -)" = '{"chart":"fixture","version":"0.1.0","tag":"fixture-0.1.0"},{"chart":"fixture","version":"0.1.0","tag":"fixture-0.1.0"}'
echo 'PASS: automatic discovery supports chart directories at the repository root.'

reset_trace
run_action --charts $'charts/one\r\ncharts/with space\n./charts/one/\ngenerated/ignored\n\n' --charts-dir unused --match-tags 'unmatched-*'
test ! -s "$FETCH_TRACE"
printf 'charts/one\ncharts/with space\ngenerated/ignored\n' > "$test_root/expected-packages"
diff -u "$test_root/expected-packages" "$CR_PACKAGE_TRACE"
test "$(cat changed_charts.txt)" = 'changed_charts=charts/one,charts/with space,generated/ignored'
test "$(cat chart_version.txt)" = 'chart_version=fixture-0.1.1,fixture-0.1.0,fixture-0.1.0'
test "$(sed 's/^releases=//' releases.txt | jq -c '.[] | {chart, version, tag}' | paste -sd ',' -)" = '{"chart":"fixture","version":"0.1.1","tag":"fixture-0.1.1"},{"chart":"fixture","version":"0.1.0","tag":"fixture-0.1.0"},{"chart":"fixture","version":"0.1.0","tag":"fixture-0.1.0"}'
git ls-remote --exit-code --heads origin refs/heads/gh-pages >/dev/null
test -z "$(git ls-tree -r --name-only refs/remotes/origin/gh-pages)"
echo 'PASS: explicit selection bypasses tags/diffs and supports spaces, CRLF, ignored charts, and deduplication.'

existing_pages_head=$(git rev-parse HEAD)
git push -q origin HEAD:refs/heads/main
git --git-dir="$test_root/origin.git" update-ref refs/heads/existing-pages "$existing_pages_head"
reset_trace
run_action --charts charts/one --pages-branch existing-pages
test "$(git rev-parse refs/remotes/origin/existing-pages)" = "$existing_pages_head"
echo 'PASS: existing publishing branches are fetched without being replaced.'

config_file="$test_root/chart-releaser.yaml"
printf 'pages-branch: "configured-pages" # custom publishing branch\n' > "$config_file"
reset_trace
run_action --charts charts/one --config "$config_file"
git ls-remote --exit-code --heads origin refs/heads/configured-pages >/dev/null
echo 'PASS: publishing branches configured in the chart-releaser config are initialized.'

reset_trace
CR_TEST_EXPECT_PAGES_BRANCH=packages-pages run_action --charts charts/one --pages-branch packages-pages --packages-with-index true
git ls-remote --exit-code --heads origin refs/heads/packages-pages >/dev/null
echo 'PASS: the publishing branch exists before packages-with-index processing.'
echo 'PASS: explicit selection bypasses tags/diffs and supports spaces, CRLF, ignored charts, and deduplication.'

custom_package_path='custom package path'
export CR_TEST_EXPECTED_PACKAGE_PATH="$custom_package_path"
reset_trace
run_action --charts charts/one --package-path "$custom_package_path" --oci-registry-url oci://ghcr.io/test/charts
test -f "$custom_package_path/fixture-0.1.1.tgz"
test "$(cat "$CR_COMMAND_TRACE")" = $'package\nupload\npush\nindex'
echo 'PASS: custom package paths are used for packaging, release upload, OCI push, and index updates.'

reset_trace
run_action --skip-packaging true --package-path "$custom_package_path"
test "$(cat "$CR_COMMAND_TRACE")" = $'upload\nindex'
test ! -e releases.txt
echo 'PASS: custom package paths are used when packaging is skipped.'
export CR_TEST_EXPECTED_PACKAGE_PATH=.cr-release-packages

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
if run_action --charts charts/one --package-path ../outside > "$test_root/unsafe-path.log" 2>&1; then
  echo 'Expected a package path outside the checkout to fail' >&2
  exit 1
fi
grep -F 'must be a relative subdirectory of the checkout' "$test_root/unsafe-path.log"
test ! -e "$test_root/outside"
test ! -s "$CR_COMMAND_TRACE"
echo 'PASS: package paths outside the checkout are rejected before creating files or running cr.'

reset_trace
if CR_FAIL_UPLOAD=true run_action --charts charts/one; then
  echo 'Expected the upload failure to propagate' >&2
  exit 1
fi
test "$(tail -1 "$CR_COMMAND_TRACE")" = upload
echo 'PASS: release failures still stop processing before index updates.'

reset_trace
env -u CR_TOKEN bash "$action_script" --owner test --repo fixtures --install-dir "$install_dir" --charts charts/one --skip-release true
test "$(cat "$CR_COMMAND_TRACE")" = package
test -f .cr-release-packages/fixture-0.1.1.tgz
test "$(cat changed_charts.txt)" = 'changed_charts=charts/one'
echo 'PASS: skip-release only packages charts and does not require CR_TOKEN.'

reset_trace
run_action --charts charts/one --skip-release true --oci-registry-url oci://registry.invalid/charts
printf 'package\npush\n' > "$test_root/expected-commands"
diff -u "$test_root/expected-commands" "$CR_COMMAND_TRACE"
echo 'PASS: skip-release still pushes to the OCI registry.'

reset_trace
if run_action --charts charts/one --skip-release true --packages-with-index true > "$test_root/skip-release.log" 2>&1; then
  echo 'Expected skip-release with packages-with-index to fail' >&2
  exit 1
fi
grep -F "'--skip-release' cannot be combined" "$test_root/skip-release.log"
test ! -s "$CR_COMMAND_TRACE"
echo 'PASS: skip-release conflicts with packages-with-index.'

git tag before-quoted-chart
mkdir -p 'charts/we"ird'
printf 'apiVersion: v2\nname: fixture\nversion: 0.1.0\n' > 'charts/we"ird/Chart.yaml'
git add 'charts/we"ird/Chart.yaml'
git commit -qm 'Add a chart whose directory name Git would quote'

reset_trace
run_action
test "$(cat "$CR_PACKAGE_TRACE")" = 'charts/we"ird'
test "$(cat changed_charts.txt)" = 'changed_charts=charts/we"ird'
echo 'PASS: automatic discovery keeps a chart directory whose path Git quotes.'

mkdir -p charts/victim
printf 'apiVersion: v2\nname: fixture\nversion: 0.1.0\n' > charts/victim/Chart.yaml
git add charts/victim/Chart.yaml
git commit -qm 'Add a chart that the line-break fixture must not reach'
git tag before-linebreak-path

mkdir -p $'charts/one/x\ncharts/victim'
printf 'apiVersion: v2\nname: fixture\nversion: 0.1.0\n' > $'charts/one/x\ncharts/victim/Chart.yaml'
git add -A
git commit -qm 'Add a path containing a line break'

reset_trace
run_action >"$test_root/linebreak.log" 2>&1
test ! -s "$CR_PACKAGE_TRACE"
test "$(cat changed_charts.txt)" = 'changed_charts='
grep -F 'line break' "$test_root/linebreak.log"
echo 'PASS: a path containing a line break cannot smuggle an unrelated chart into the run.'
