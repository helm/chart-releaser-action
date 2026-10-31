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

action_script="${CR_ACTION_SCRIPT:-$(git rev-parse --show-toplevel)/cr.sh}"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export RUNNER_TOOL_CACHE="$test_root/cache"
export CR_TEST_TRACE="$test_root/trace"
install_dir="$RUNNER_TOOL_CACHE/cr"
mkdir -p "$install_dir" "$test_root/repo/charts/example"

# Stand in for the CLI at the process boundary: validate the effective mode on
# both commands and record package bytes. Upstream tests cover asset mutation.
cat > "$install_dir/cr" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
command="$1"
shift
if [[ "$command" == package ]]; then
  fixture_dir=$(mktemp -d)
  mkdir -p "$fixture_dir/example"
  cp "$1/Chart.yaml" "$fixture_dir/example/Chart.yaml"
  tar -czf "$3/example-1.0.0.tgz" -C "$fixture_dir" example
  rm -rf "$fixture_dir"
  exit
fi
skip="${CR_SKIP_EXISTING:-false}"
for arg in "$@"; do
  [[ "$arg" != --skip-existing ]] || skip=true
done
replace=false
case "${CR_REPLACE_EXISTING:-false}" in
1 | t | T | true | TRUE | True) replace=true ;;
esac
printf '%s replace=%s skip=%s' "$command" "$replace" "$skip" >> "$CR_TEST_TRACE"
printf ' %s' "$@" >> "$CR_TEST_TRACE"
printf '\n' >> "$CR_TEST_TRACE"
if [[ "$replace" == true && "$skip" == true ]]; then
  echo 'specify either --skip-existing or --replace-existing, but not both' >&2
  exit 1
fi
if [[ "$command" == upload && "${CR_TEST_FAIL_UPLOAD:-false}" == true ]]; then
  exit 42
fi
cksum .cr-release-packages/*.tgz >> "$CR_TEST_TRACE"
CLI
chmod +x "$install_dir/cr"

cd "$test_root/repo"
git init -q -b main
git config user.name test
git config user.email test@example.invalid
git config commit.gpgsign false
printf 'apiVersion: v2\nname: example\nversion: 1.0.0\n' > charts/example/Chart.yaml
git add charts
git commit -qm 'Unchanged chart'
unset CR_REPLACE_EXISTING CR_SKIP_EXISTING

run_action() {
  : > "$CR_TEST_TRACE"
  CR_TOKEN=fake bash "$action_script" --owner test --repo fixtures --install-dir "$install_dir" "$@"
}

for pages in false true; do
  for value in true True TRUE t T 1; do
    CR_REPLACE_EXISTING="$value" run_action --charts charts/example --packages-with-index "$pages"
    grep -q '^upload replace=true skip=false' "$CR_TEST_TRACE"
    grep -q '^index replace=true skip=false' "$CR_TEST_TRACE"
    if [[ "$pages" == true ]]; then
      grep -q '^upload .* --packages-with-index --push' "$CR_TEST_TRACE"
      grep -q '^index .* --packages-with-index' "$CR_TEST_TRACE"
    fi
    test "$(sed -n '2p' "$CR_TEST_TRACE")" = "$(sed -n '4p' "$CR_TEST_TRACE")"
    test "$(cat changed_charts.txt)" = 'changed_charts=charts/example'
  done
  echo "PASS: explicit chart replacement reaches upload and index with identical packages (Pages=$pages)."

  # Recovery can use the existing packages without packaging them again.
  CR_REPLACE_EXISTING=true run_action --skip-packaging true --packages-with-index "$pages"
  grep -q '^index replace=true skip=false' "$CR_TEST_TRACE"

  for conflict in input environment; do
    args=(--charts charts/example --packages-with-index "$pages")
    if [[ "$conflict" == input ]]; then
      args+=(--skip-existing true)
      export CR_SKIP_EXISTING=false
    else
      export CR_SKIP_EXISTING=true
    fi
    if CR_REPLACE_EXISTING=true run_action "${args[@]}" > "$test_root/conflict.log" 2>&1; then
      echo 'Expected conflicting modes to fail' >&2
      exit 1
    fi
    grep -q 'specify either' "$test_root/conflict.log"
    if grep -q '^index ' "$CR_TEST_TRACE"; then
      echo 'Index must not run after conflicting publishing modes' >&2
      exit 1
    fi
    unset CR_SKIP_EXISTING
  done

  if CR_TEST_FAIL_UPLOAD=true CR_REPLACE_EXISTING=true run_action --charts charts/example --packages-with-index "$pages"; then
    echo 'Expected upload failure to stop the action' >&2
    exit 1
  fi
  if grep -q '^index ' "$CR_TEST_TRACE"; then
    echo 'Index must not run after upload failure' >&2
    exit 1
  fi
  echo "PASS: conflicts and upload failures stop before index (Pages=$pages)."
done

run_action --charts charts/example
grep -q '^upload replace=false skip=false' "$CR_TEST_TRACE"
for value in false False FALSE f F 0 ''; do
  CR_REPLACE_EXISTING="$value" run_action --charts charts/example --packages-with-index true
  grep -q '^upload replace=false skip=true' "$CR_TEST_TRACE"
done
echo 'PASS: default release behavior and Pages skipping remain unchanged.'
