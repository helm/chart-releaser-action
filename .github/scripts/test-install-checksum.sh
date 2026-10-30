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
export RUNNER_TOOL_CACHE="$test_root/cache"
export RELEASE_FIXTURES="$test_root/release"
version=v9.9.9
tarball="chart-releaser_${version#v}_linux_amd64.tar.gz"
mkdir -p "$test_root/bin" "$RUNNER_TOOL_CACHE" "$RELEASE_FIXTURES" "$test_root/payload"

# Fake release: a tarball holding a stub cr binary, plus its checksums.txt.
printf '#!/usr/bin/env bash\necho fake-cr\n' > "$test_root/payload/cr"
chmod +x "$test_root/payload/cr"
tar -czf "$RELEASE_FIXTURES/$tarball" -C "$test_root/payload" cr

write_checksums() {
  (cd "$RELEASE_FIXTURES" && sha256sum "$tarball" > checksums.txt)
  printf '%s  %s.sbom.json\n' "$(printf 0%.0s {1..64})" "$tarball" >> "$RELEASE_FIXTURES/checksums.txt"
}

# Stub curl serves release assets from the fixture directory.
cat > "$test_root/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
out= url=
while [[ $# -gt 0 ]]; do
  case "$1" in
    -*o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
src="$RELEASE_FIXTURES/${url##*/}"
[[ -f "$src" ]] || { echo "curl: (22) 404 for $url" >&2; exit 22; }
cp "$src" "$out"
STUB
chmod +x "$test_root/bin/curl"
export PATH="$test_root/bin:$PATH"

run_install() {
  local install_dir="$1"
  CR_TOKEN=fake bash "$action_script" --version "$version" --owner test --repo fixtures --install-dir "$install_dir" --install-only true
}

work_dir="$test_root/work"
mkdir -p "$work_dir"
cd "$work_dir"

# 1. Matching checksum installs cr.
write_checksums
run_install "$RUNNER_TOOL_CACHE/ok" > "$test_root/ok.log" 2>&1 || { cat "$test_root/ok.log"; exit 1; }
if [[ ! -x "$RUNNER_TOOL_CACHE/ok/cr" ]]; then
  cat "$test_root/ok.log"
  echo 'cr should be installed when the checksum matches' >&2
  exit 1
fi
grep -q "Verified checksum of $tarball" "$test_root/ok.log"

# 2. Tampered tarball is rejected and nothing is installed.
printf 'tampered' >> "$RELEASE_FIXTURES/$tarball"
if run_install "$RUNNER_TOOL_CACHE/tampered" > "$test_root/tampered.log" 2>&1; then
  echo 'install should fail when the checksum does not match' >&2
  exit 1
fi
grep -q "Checksum mismatch for $tarball" "$test_root/tampered.log"
[[ ! -e "$RUNNER_TOOL_CACHE/tampered" ]] || { echo 'install dir should be removed after a failed check' >&2; exit 1; }

# 3. Missing checksum entry is rejected.
printf '%s  some-other-file.tar.gz\n' "$(printf 0%.0s {1..64})" > "$RELEASE_FIXTURES/checksums.txt"
if run_install "$RUNNER_TOOL_CACHE/missing" > "$test_root/missing.log" 2>&1; then
  echo 'install should fail when checksums.txt has no entry for the tarball' >&2
  exit 1
fi
grep -q "No checksum for $tarball" "$test_root/missing.log"

# 4. Missing checksums.txt is a download error.
rm "$RELEASE_FIXTURES/checksums.txt"
if run_install "$RUNNER_TOOL_CACHE/nochecksums" > "$test_root/nochecksums.log" 2>&1; then
  echo 'install should fail when checksums.txt cannot be downloaded' >&2
  exit 1
fi

# The work directory stays clean.
if [[ -n "$(ls -A "$work_dir")" ]]; then
  echo 'install should not leave files in the working directory' >&2
  exit 1
fi

echo 'install checksum tests passed'
