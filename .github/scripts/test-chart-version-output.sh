#!/usr/bin/env bash

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

runner_tool_cache="$test_root/tool-cache"
install_dir="$runner_tool_cache/cr/v1.7.0/$(uname -m)"
mkdir -p "$install_dir"

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

  version=$(awk '/^version:/ {print $2; exit}' "$chart/Chart.yaml")
  tarball="$(basename "$chart")-$version.tgz"
  : >"$package_path/$tarball"
  ;;
upload|index)
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