#!/usr/bin/env bash

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

runner_tool_cache="$test_root/tool-cache"
install_dir="$runner_tool_cache/cr/v1.7.0/$(uname -m)"
mkdir -p "$install_dir"

export CR_TEST_PACKAGE_FIXTURES="$test_root/packages"

prepare_packages() {
  local chart destination
  for chart in "$test_repo/charts/"*; do
    destination="$CR_TEST_PACKAGE_FIXTURES/$(basename "$chart")"
    mkdir -p "$destination"
    helm package "$chart" --destination "$destination" >/dev/null
  done
}

cat >"$install_dir/cr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command="$1"
shift

case "$command" in
package)
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

  cp "$CR_TEST_PACKAGE_FIXTURES/$(basename "$chart")/"*.tgz "$package_path/"
  if [[ "${CR_TEST_CORRUPT_PACKAGE:-false}" == true ]]; then
    for package in "$package_path/"*.tgz; do
      : >"$package"
    done
  fi
  ;;
upload|index)
  echo "$command" >>"$CR_TEST_PUBLISH_LOG"
  ;;
*)
  echo "unexpected command: $command" >&2
  exit 1
  ;;
esac
EOF
chmod +x "$install_dir/cr"

test_repo="$test_root/repo"
mkdir -p "$test_repo/charts/common-service"
cd "$test_repo"

git init >/dev/null
git config user.name test
git config user.email test@example.com

cat >charts/common-service/Chart.yaml <<'EOF'
apiVersion: v2
name: common-service
version: 0.1.1
EOF

git add charts/common-service/Chart.yaml
git commit -m "initial chart" >/dev/null
git tag common-service-0.1.1

cat >charts/common-service/Chart.yaml <<'EOF'
apiVersion: v2
name: common-service
version: 0.1.2
EOF

git add charts/common-service/Chart.yaml
git commit -m "bump chart version" >/dev/null

export CR_TOKEN=fake-token
export RUNNER_TOOL_CACHE="$runner_tool_cache"
export CR_TEST_PUBLISH_LOG="$test_root/publish.log"

prepare_packages
bash "$repo_root/cr.sh" --owner helm --repo chart-releaser-action --install-dir "$install_dir"

expected_changed='changed_charts=charts/common-service'
expected_version='chart_version=common-service-0.1.2'
actual_changed=$(<changed_charts.txt)
actual_version=$(<chart_version.txt)

if [[ "$actual_changed" != "$expected_changed" ]]; then
  echo "expected '$expected_changed' but got '$actual_changed'" >&2
  exit 1
fi

if [[ "$actual_version" != "$expected_version" ]]; then
  echo "expected '$expected_version' but got '$actual_version'" >&2
  exit 1
fi

git tag common-service-0.1.2

mkdir -p charts/app charts/app-0helper charts/different-directory

cat >charts/app/Chart.yaml <<'EOF'
apiVersion: v2
name: app
version: 1.0.0
EOF

cat >charts/app-0helper/Chart.yaml <<'EOF'
apiVersion: v2
name: app-0helper
version: 2.0.0
EOF

cat >charts/different-directory/Chart.yaml <<'EOF'
apiVersion: v2
name: "actual-chart-name" # Not the directory name
version: '3.0.0' # Quoted chart version
EOF

git add charts
git commit -m "add charts with overlapping and differing names" >/dev/null

prepare_packages
bash "$repo_root/cr.sh" --owner helm --repo chart-releaser-action --install-dir "$install_dir"

expected_changed='changed_charts=charts/app-0helper,charts/app,charts/different-directory'
expected_version='chart_version=app-0helper-2.0.0,app-1.0.0,actual-chart-name-3.0.0'
actual_changed=$(<changed_charts.txt)
actual_version=$(<chart_version.txt)

if [[ "$actual_changed" != "$expected_changed" ]]; then
  echo "expected '$expected_changed' but got '$actual_changed'" >&2
  exit 1
fi

if [[ "$actual_version" != "$expected_version" ]]; then
  echo "expected '$expected_version' but got '$actual_version'" >&2
  exit 1
fi

runtime_bin="$test_root/runtime-bin"
mkdir -p "$runtime_bin"
for runtime_command in awk bash basename cat cp cut git gzip mkdir rm sed sh tar tr uname uniq wc; do
  command_path=$(command -v "$runtime_command")
  printf '#!%s\nexec %q "$@"\n' "$BASH" "$command_path" >"$runtime_bin/$runtime_command"
  chmod +x "$runtime_bin/$runtime_command"
done

if PATH="$runtime_bin" bash -c 'command -v helm'; then
  echo "expected Helm to be unavailable on the simulated runner" >&2
  exit 1
fi

rm -f chart_version.txt "$CR_TEST_PUBLISH_LOG"
PATH="$runtime_bin" bash "$repo_root/cr.sh" --owner helm --repo chart-releaser-action --install-dir "$install_dir"

if [[ "$(<chart_version.txt)" != "$expected_version" ]]; then
  echo "expected correct chart versions on a runner without Helm" >&2
  exit 1
fi

if [[ "$(<"$CR_TEST_PUBLISH_LOG")" != $'upload\nindex' ]]; then
  echo "expected upload and index to succeed on a runner without Helm" >&2
  exit 1
fi

rm -f chart_version.txt "$CR_TEST_PUBLISH_LOG"
if PATH="$runtime_bin" CR_TEST_CORRUPT_PACKAGE=true bash "$repo_root/cr.sh" --owner helm --repo chart-releaser-action --install-dir "$install_dir"; then
  echo "expected a nonzero action exit when package metadata lookup fails" >&2
  exit 1
fi

if [[ -f chart_version.txt || -f "$CR_TEST_PUBLISH_LOG" ]]; then
  echo "metadata lookup failure must not write chart_version or publish charts" >&2
  exit 1
fi

echo "chart_version output tests passed"