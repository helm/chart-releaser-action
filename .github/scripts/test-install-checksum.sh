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

repo_root=$(git rev-parse --show-toplevel)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

export CR_TEST_ARCHIVE="$test_root/archive"
export CR_TEST_TAR_TRACE="$test_root/tar.trace"
mkdir -p "$test_root/bin" "$test_root/cache"
printf 'fake chart-releaser archive\n' >"$CR_TEST_ARCHIVE"

cat >"$test_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output="$2"
url="$3"
case "$url" in
*/checksums.txt)
  checksum=$(shasum -a 256 "$CR_TEST_ARCHIVE" | cut -d ' ' -f 1)
  if [[ "${CR_TEST_BAD_CHECKSUM:-false}" == true ]]; then
    if [[ "${checksum:0:1}" == 0 ]]; then
      checksum="1${checksum:1}"
    else
      checksum="0${checksum:1}"
    fi
  fi
  printf '%s  chart-releaser_test_linux_amd64.tar.gz\n' "$checksum" >"$output"
  ;;
*)
  cp "$CR_TEST_ARCHIVE" "$output"
  ;;
esac
EOF

cat >"$test_root/bin/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo extract >>"$CR_TEST_TAR_TRACE"
install_dir="${@: -1}"
printf '#!/usr/bin/env bash\nexit 0\n' >"$install_dir/cr"
chmod +x "$install_dir/cr"
EOF
chmod +x "$test_root/bin/curl" "$test_root/bin/tar"
export PATH="$test_root/bin:$PATH"
export RUNNER_TOOL_CACHE="$test_root/cache"

run_install() {
  local install_dir="$1"
  CR_TOKEN=fake bash "$repo_root/cr.sh" \
    --owner test \
    --repo fixtures \
    --version vtest \
    --install-dir "$install_dir" \
    --install-only true
}

if CR_TEST_BAD_CHECKSUM=true run_install "$test_root/cache/bad" >"$test_root/bad.log" 2>&1; then
  echo "Expected installation to fail for an invalid checksum." >&2
  exit 1
fi
grep -F "Checksum verification failed" "$test_root/bad.log"
test ! -s "$CR_TEST_TAR_TRACE"
test ! -e "$test_root/cache/bad/cr"
test ! -e "$test_root/cache/bad" || { echo "install dir should be removed after checksum failure" >&2; exit 1; }

echo "PASS: an invalid checksum prevents archive extraction."

run_install "$test_root/cache/good"
test -x "$test_root/cache/good/cr"
test "$(cat "$CR_TEST_TAR_TRACE")" = extract
echo "PASS: a valid checksum allows archive extraction."
