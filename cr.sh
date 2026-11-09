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

set -o errexit
set -o nounset
set -o pipefail

DEFAULT_CHART_RELEASER_VERSION=v1.10.1

show_help() {
  cat <<EOF
Usage: $(basename "$0") <options>

    -h, --help                    Display help
    -v, --version                 The chart-releaser version to use (default: $DEFAULT_CHART_RELEASER_VERSION)"
        --config                  The path to the chart-releaser config file
    -d, --charts-dir              The charts directory (default: charts)
        --charts                  Newline-separated chart directories to process without Git change detection
        --ignore-paths            Newline-separated glob patterns to ignore during Git change detection
        --package-path            Directory for chart packages (default: .cr-release-packages)
    -o, --owner                   The repo owner
    -r, --repo                    The repo name
        --pages-branch            The repo pages branch
    -n, --install-dir             The Path to install the cr tool
    -i, --install-only            Just install the cr tool
    -s, --skip-packaging          Skip the packaging step (run your own packaging before using the releaser)
        --skip-existing           Skip package upload if release exists
        --skip-upload             Skip package upload, just create the release. Not needed in case of OCI upload.
        --skip-release            Skip creating GitHub releases and updating the index; only package (and push to OCI if configured)
    -l, --mark-as-latest          Mark the created GitHub release as 'latest' (default: true)
    -m, --match-tags              The glob to use to filter Git tags (default: all tags)
        --packages-with-index     Upload chart packages directly into publishing branch
        --oci-registry-url        OCI registry URL (e.g. oci://ghcr.io/myorg/charts). When set, packages are pushed via 'cr push'.
        --oci-username            Username for OCI registry authentication (falls back to local registry credential store)
        --oci-password            Password/token for OCI registry authentication (falls back to local registry credential store)
        --use-arm                 Use ARM64 binary (default: false)
EOF
}

main() {
  local version="$DEFAULT_CHART_RELEASER_VERSION"
  local config=
  local charts_dir=charts
  local charts=
  local ignore_paths=
  local package_path=.cr-release-packages
  local owner=
  local repo=
  local match_tags=
  local install_dir=
  local install_only=
  local skip_packaging=
  local skip_existing=
  local skip_upload=
  local skip_release=false
  local mark_as_latest=true
  local packages_with_index=false
  local pages_branch=
  local oci_registry_url=
  local oci_username=
  local oci_password=
  local use_arm=false

  parse_command_line "$@"

  if [[ -n "$charts" && -n "$skip_packaging" ]]; then
    echo "ERROR: '--charts' cannot be combined with '--skip-packaging'." >&2
    exit 1
  fi

  if [[ "$skip_release" = true && "$packages_with_index" = true ]]; then
    echo "ERROR: '--skip-release' cannot be combined with '--packages-with-index'." >&2
    exit 1
  fi

  if [[ "$skip_release" != true ]]; then
    : "${CR_TOKEN:?Environment variable CR_TOKEN must be set}"
  fi

  local repo_root
  repo_root=$(git rev-parse --show-toplevel)
  pushd "$repo_root" >/dev/null
  rm -f changed_charts.txt chart_version.txt releases.txt

  if [[ -z "$skip_packaging" ]]; then
    local latest_tag=
    local changed_charts=()
    if [[ -n "$charts" ]]; then
      echo 'Processing explicitly selected charts...'
      local selected_charts
      selected_charts=$(lookup_selected_charts "$charts")
      readarray -t changed_charts <<<"$selected_charts"
    else
      echo 'Looking up latest tag...'
      latest_tag=$(lookup_latest_tag)

      echo "Discovering changed charts since '$latest_tag'..."
      readarray -t changed_charts <<<"$(lookup_changed_charts "$latest_tag")"
    fi

    if [[ -n "${changed_charts[*]}" ]]; then
      prepare_package_path || return 1
      install_chart_releaser

      clear_package_path || return 1

      rm -rf .cr-index
      mkdir -p .cr-index

      local packaged_chart_versions=()
      local packaged_chart_releases=()
      for chart in "${changed_charts[@]}"; do
        if [[ -d "$chart" ]]; then
          package_chart "$chart" || return 1
        else
          echo "Nothing to do. No chart changes detected."
        fi
      done

      local chart_versions
      chart_versions=$(
        IFS=,
        echo "${packaged_chart_versions[*]}"
      )

      release_charts
      push_charts
      update_index
      echo "changed_charts=$(
        IFS=,
        echo "${changed_charts[*]}"
      )" >changed_charts.txt

      echo "chart_version=$chart_versions" >chart_version.txt
      local releases_json
      if ! releases_json=$(printf '%s\n' "${packaged_chart_releases[@]}" | jq -sc '.'); then
        echo "ERROR: Failed to encode release output as JSON." >&2
        return 1
      fi
      printf 'releases=%s\n' "$releases_json" >releases.txt
    else
      echo "Nothing to do. No chart changes detected."
      echo "changed_charts=" >changed_charts.txt
      echo "chart_version=" >chart_version.txt
      echo 'releases=[]' >releases.txt
    fi
  else
    prepare_package_path || return 1
    install_chart_releaser
    rm -rf .cr-index
    mkdir -p .cr-index
    release_charts
    push_charts
    update_index
  fi

  popd >/dev/null
}

parse_command_line() {
  while :; do
    case "${1:-}" in
    -h | --help)
      show_help
      exit
      ;;
    --config)
      if [[ -n "${2:-}" ]]; then
        config="$2"
        shift
      else
        echo "ERROR: '--config' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -v | --version)
      if [[ -n "${2:-}" ]]; then
        version="$2"
        shift
      else
        echo "ERROR: '-v|--version' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    --charts)
      if [[ -n "${2:-}" ]]; then
        charts="$2"
        shift
      else
        echo "ERROR: '--charts' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    --ignore-paths)
      if [[ -n "${2:-}" ]]; then
        ignore_paths="$2"
        shift
      else
        echo "ERROR: '--ignore-paths' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    --package-path)
      if [[ -n "${2:-}" ]]; then
        package_path="$2"
        shift
      else
        echo "ERROR: '--package-path' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -d | --charts-dir)
      if [[ -n "${2:-}" ]]; then
        charts_dir="$2"
        shift
      else
        echo "ERROR: '-d|--charts-dir' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -o | --owner)
      if [[ -n "${2:-}" ]]; then
        owner="$2"
        shift
      else
        echo "ERROR: '--owner' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -r | --repo)
      if [[ -n "${2:-}" ]]; then
        repo="$2"
        shift
      else
        echo "ERROR: '--repo' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    --pages-branch)
      if [[ -n "${2:-}" ]]; then
        pages_branch="$2"
        shift
      fi
      ;;
    -m|--match-tags)
      if [[ -n "${2:-}" ]]; then
        match_tags="$2"
        shift
      else
        echo "ERROR: '--match-tags' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -n | --install-dir)
      if [[ -n "${2:-}" ]]; then
        install_dir="$2"
        shift
      fi
      ;;
    -i | --install-only)
      if [[ -n "${2:-}" ]]; then
        install_only="$2"
        shift
      fi
      ;;
    -s | --skip-packaging)
      if [[ -n "${2:-}" ]]; then
        skip_packaging="$2"
        shift
      fi
      ;;
    --skip-existing)
      if [[ -n "${2:-}" ]]; then
        skip_existing="$2"
        shift
      fi
      ;;
    --skip-upload)
      if [[ -n "${2:-}" ]]; then
          skip_upload="$2"
          shift
      fi
      ;;
    --skip-release)
      if [[ -n "${2:-}" ]]; then
        skip_release="$2"
        shift
      fi
      ;;
    -l | --mark-as-latest)
      if [[ -n "${2:-}" ]]; then
        mark_as_latest="$2"
        shift
      fi
      ;;
    --packages-with-index)
      if [[ -n "${2:-}" ]]; then
        packages_with_index="$2"
        shift
      fi
      ;;
    --oci-registry-url)
      if [[ -n "${2:-}" ]]; then
        oci_registry_url="$2"
        shift
      fi
      ;;
    --oci-username)
      if [[ -n "${2:-}" ]]; then
        oci_username="$2"
        shift
      fi
      ;;
    --oci-password)
      if [[ -n "${2:-}" ]]; then
        oci_password="$2"
        shift
      fi
      ;;
    --use-arm)
      if [[ -n "${2:-}" ]]; then
          use_arm="$2"
          shift
      fi
      ;;
    *)
      break
      ;;
    esac

    shift
  done

  if [[ -z "$owner" ]]; then
    echo "ERROR: '-o|--owner' is required." >&2
    show_help
    exit 1
  fi

  if [[ -z "$repo" ]]; then
    echo "ERROR: '-r|--repo' is required." >&2
    show_help
    exit 1
  fi

  if [[ -z "$install_dir" ]]; then
    local arch
    arch=$(uname -m)
    install_dir="$RUNNER_TOOL_CACHE/cr/$version/$arch"
  fi

  if [[ -n "$install_only" ]]; then
    echo "Will install cr tool and not run it..."
    install_chart_releaser
    exit 0
  fi
}



install_chart_releaser() {
  if [[ ! -d "$RUNNER_TOOL_CACHE" ]]; then
    echo "Cache directory '$RUNNER_TOOL_CACHE' does not exist" >&2
    exit 1
  fi

  if [[ ! -d "$install_dir" ]]; then
    mkdir -p "$install_dir"
    architecture=linux_amd64
    if [[ "$use_arm" = true ]]; then
      architecture=linux_arm64
    fi
    echo "Installing chart-releaser on $install_dir..."
    local archive="chart-releaser_${version#v}_${architecture}.tar.gz"
    local release_url="https://github.com/helm/chart-releaser/releases/download/$version"
    local download_dir
    download_dir=$(mktemp -d)

    cleanup_failed_install() {
      rm -rf "$download_dir" "$install_dir"
    }

    if ! curl -fsSLo "$download_dir/$archive" "$release_url/$archive"; then
      echo "ERROR: Failed to download chart-releaser archive '$archive'." >&2
      cleanup_failed_install
      return 1
    fi
    if ! curl -fsSLo "$download_dir/checksums.txt" "$release_url/checksums.txt"; then
      echo "ERROR: Failed to download chart-releaser checksums." >&2
      cleanup_failed_install
      return 1
    fi

    local checksum_line
    if ! checksum_line=$(awk -v archive="$archive" '$2 == archive { print; count++ } END { if (count != 1) exit 1 }' "$download_dir/checksums.txt"); then
      echo "ERROR: Expected exactly one checksum for '$archive'." >&2
      cleanup_failed_install
      return 1
    fi
    local expected_checksum="${checksum_line%%[[:space:]]*}"
    local actual_checksum
    if ! actual_checksum=$(shasum -a 256 "$download_dir/$archive" | awk '{ print $1 }'); then
      echo "ERROR: Failed to calculate checksum for '$archive'." >&2
      cleanup_failed_install
      return 1
    fi
    if [[ "$actual_checksum" != "$expected_checksum" ]]; then
      echo "ERROR: Checksum verification failed for '$archive'." >&2
      cleanup_failed_install
      return 1
    fi
    if ! tar -xzf "$download_dir/$archive" -C "$install_dir"; then
      echo "ERROR: Failed to extract chart-releaser archive '$archive'." >&2
      cleanup_failed_install
      return 1
    fi
    rm -rf "$download_dir"
  fi

  echo 'Adding cr directory to PATH...'
  export PATH="$install_dir:$PATH"
}

lookup_latest_tag() {
  git fetch --tags >/dev/null 2>&1

  args=("describe" "--tags" "--abbrev=0")
  if [ -n "$match_tags" ]; then
    args+=(--match="$match_tags")
  fi
  args+=(HEAD~)

  if ! git "${args[@]}" 2> /dev/null; then
    git rev-list --max-parents=0 --first-parent HEAD
  fi
}

lookup_selected_charts() {
  local chart resolved existing duplicate
  local selected=() resolved_paths=()
  while IFS= read -r chart || [[ -n "$chart" ]]; do
    chart=${chart%$'\r'}
    [[ -z "${chart//[[:space:]]/}" ]] && continue
    if [[ ! -d "$chart" || ! -f "$chart/Chart.yaml" ]]; then
      echo "ERROR: Selected chart '$chart' must be a directory containing Chart.yaml." >&2
      return 1
    fi
    resolved=$(cd "$chart" && pwd -P)
    duplicate=false
    for existing in "${resolved_paths[@]}"; do
      if [[ "$existing" == "$resolved" ]]; then
        duplicate=true
        break
      fi
    done
    if [[ "$duplicate" = false ]]; then
      selected+=("$chart")
      resolved_paths+=("$resolved")
    fi
  done <<<"$1"

  if [[ ${#selected[@]} -eq 0 ]]; then
    echo "ERROR: '--charts' must contain at least one chart directory." >&2
    return 1
  fi
  printf '%s\n' "${selected[@]}"
}

filter_charts() {
  while read -r chart; do
    [[ ! -d "$chart" ]] && continue
    local file="$chart/Chart.yaml"
    if [[ -f "$file" ]]; then
      echo "$chart"
    else
      echo "WARNING: $file is missing, assuming that '$chart' is not a Helm chart. Skipping." 1>&2
    fi
  done
}

lookup_changed_charts() {
  local commit="$1"

  local changed_files
  changed_files=$(git -c core.quotePath=false diff --find-renames --name-only "$commit" -- "$charts_dir")

  local depth fields changed_file chart relative_path pattern ignored
  depth=$(($(tr "/" "\n" <<<"$charts_dir" | sed '/^\(\.\)*$/d' | wc -l) + 1))
  fields="1-${depth}"

  local changed_charts=() existing duplicate
  while IFS= read -r changed_file; do
    [[ -z "$changed_file" ]] && continue
    chart=$(cut -d '/' -f "$fields" <<<"$changed_file")
    relative_path=${changed_file#"$chart"/}
    ignored=false
    while IFS= read -r pattern || [[ -n "$pattern" ]]; do
      pattern=${pattern%$'\r'}
      [[ -z "${pattern//[[:space:]]/}" ]] && continue
      if [[ "$relative_path" == $pattern ]]; then
        ignored=true
        break
      fi
    done <<<"$ignore_paths"
    [[ "$ignored" == true ]] && continue

    duplicate=false
    for existing in "${changed_charts[@]}"; do
      if [[ "$existing" == "$chart" ]]; then
        duplicate=true
        break
      fi
    done
    [[ "$duplicate" == false ]] && changed_charts+=("$chart")
  done <<<"$changed_files"

  printf '%s\n' "${changed_charts[@]}" | filter_charts
}

package_chart() {
  local chart="$1"
  local tmp_dir=".cr-package-tmp"

  local args=("$chart" --package-path "$tmp_dir")
  if [[ -n "$config" ]]; then
    args+=(--config "$config")
  fi

  rm -rf "$tmp_dir" || return 1
  mkdir -p "$tmp_dir" || return 1

  echo "Packaging chart '$chart'..."
  cr package "${args[@]}" || return 1

  local packages=("$tmp_dir"/*.tgz)
  if [[ ${#packages[@]} -ne 1 || ! -f "${packages[0]}" ]]; then
    echo "ERROR: Expected exactly one package for '$chart' in $tmp_dir" >&2
    return 1
  fi

  local packaged_metadata packaged_chart_name packaged_chart_version packaged_identity
  if ! packaged_metadata=$(lookup_packaged_chart_metadata "${packages[0]}"); then
    echo "ERROR: Failed to read packaged chart metadata for '$chart'" >&2
    return 1
  fi
  IFS=$'\t' read -r packaged_chart_name packaged_chart_version <<<"$packaged_metadata"
  packaged_identity="$packaged_chart_name-$packaged_chart_version"

  if [[ "$(basename "${packages[0]}" .tgz)" != "$packaged_identity" ]]; then
    echo "ERROR: Packaged chart filename does not match '$packaged_identity'" >&2
    return 1
  fi

  cp -f "${packages[0]}" "$package_path/" || return 1
  if [[ -f "${packages[0]}.prov" ]]; then
    cp -f "${packages[0]}.prov" "$package_path/" || return 1
  fi
  local release_json
  if ! release_json=$(jq -cn \
    --arg chart "$packaged_chart_name" \
    --arg version "$packaged_chart_version" \
    --arg tag "$packaged_identity" \
    '{chart: $chart, version: $version, tag: $tag}'); then
    echo "ERROR: Failed to encode release output for '$chart' as JSON." >&2
    return 1
  fi
  packaged_chart_releases+=("$release_json")
  packaged_chart_versions+=("$packaged_identity")
  rm -rf "$tmp_dir"
}

clear_package_path() {
  local package
  for package in "$package_path"/*.tgz "$package_path"/*.tgz.prov; do
    if [[ -f "$package" ]]; then
      rm -f "$package" || return 1
    fi
  done
}

prepare_package_path() {
  if [[ "$package_path" == /* || "/$package_path/" == *"/../"* ]]; then
    echo "ERROR: Package path must be a relative subdirectory of the checkout." >&2
    return 1
  fi
  if [[ "$package_path" == -* ]]; then
    package_path="./$package_path"
  fi
  mkdir -p "$package_path" || return 1

  local resolved_path resolved_repo_root
  resolved_path=$(cd "$package_path" && pwd -P) || return 1
  resolved_repo_root=$(cd "$repo_root" && pwd -P) || return 1
  case "$resolved_path" in
    "$resolved_repo_root"/*)
      ;;
    *)
      echo "ERROR: Package path must be a subdirectory of the checkout." >&2
      return 1
      ;;
  esac
}

lookup_packaged_chart_metadata() {
  local chart="$1"
  local metadata metadata_path

  metadata_path=$(tar -tzf "$chart" | awk '
    /^[^\/]+\/Chart\.yaml$/ { print; count++ }
    END { if (count != 1) exit 1 }
  ') || return 1
  metadata=$(tar -xOzf "$chart" "$metadata_path") || return 1

  awk '
    function scalar(value) {
      sub(/^[^:]*:[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        value = substr(value, 2, length(value) - 2)
      }
      return value
    }
    /^name:/ { name = scalar($0) }
    /^version:/ { version = scalar($0) }
    END {
      if (name !~ /^[[:alnum:]][[:alnum:]._-]*$/ || version !~ /^[[:alnum:]][[:alnum:].+_-]*$/) {
        exit 1
      }
      printf "%s\t%s\n", name, version
    }
  ' <<<"$metadata"
}

release_charts() {
  if [[ "$skip_release" = true ]]; then
    echo 'Skipping GitHub release...'
    return
  fi

  if [[ "$packages_with_index" = true || -z "$skip_upload" ]]; then
    ensure_pages_branch
  fi

  local args=(-o "$owner" -r "$repo" -c "$(git rev-parse HEAD)")
  args+=(--package-path "$package_path")
  if [[ -n "$config" ]]; then
    args+=(--config "$config")
  fi
  if [[ "$packages_with_index" = true ]]; then
    args+=(--packages-with-index --push)
  fi
  if [[ -n "$skip_existing" ]]; then
    args+=(--skip-existing)
  elif [[ "$packages_with_index" = true ]]; then
    # Match the true values accepted by the CLI's Go boolean parser. Leave
    # replacement in the environment so upload and index receive the same mode.
    case "${CR_REPLACE_EXISTING:-false}" in
    1 | t | T | true | TRUE | True) ;;
    *) args+=(--skip-existing) ;;
    esac
  fi
  if [[ "$mark_as_latest" = false ]]; then
    args+=(--make-release-latest=false)
  fi
  if [[ -n "$pages_branch" ]]; then
    args+=(--pages-branch "$pages_branch")
  fi

  echo 'Releasing charts...'
  cr upload "${args[@]}"
}

push_charts() {
  if [[ -z "$oci_registry_url" ]]; then
    return
  fi

  local args=(--registry-url "$oci_registry_url" --package-path "$package_path")
  if [[ -n "$oci_username" ]]; then
    args+=(--username "$oci_username")
  fi
  if [[ -n "$oci_password" ]]; then
    args+=(--password "$oci_password")
  fi
  if [[ -n "$skip_existing" ]]; then
    args+=(--skip-existing)
  fi

  echo "Pushing charts to OCI registry $oci_registry_url..."
  cr push "${args[@]}"
}

update_index() {
  if [[ -n "$skip_upload" || "$skip_release" = true ]]; then
    echo "Skipping index upload..."
    return
  fi

  ensure_pages_branch

  local args=(-o "$owner" -r "$repo" --push)
  args+=(--package-path "$package_path")
  if [[ -n "$config" ]]; then
    args+=(--config "$config")
  fi
  if [[ "$packages_with_index" = true ]]; then
    args+=(--packages-with-index)
  fi
  if [[ -n "$pages_branch" ]]; then
    args+=(--pages-branch "$pages_branch")
  fi

  echo 'Updating charts repo index...'
  cr index "${args[@]}"
}

read_config_value() {
  local key="$1"
  local config_file="$config"
  if [[ -z "$config" ]]; then
    config_file="${HOME:-}/.cr.yaml"
    if [[ ! -f "$config_file" ]]; then
      return
    fi
  fi
  if [[ ! -f "$config_file" ]]; then
    echo "ERROR: Configuration file '$config_file' does not exist." >&2
    return 1
  fi

  local value
  if ! value=$(awk -v key="$key" '
    function trim(text) {
      sub(/^[[:space:]]+/, "", text)
      sub(/[[:space:]]+$/, "", text)
      return text
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line !~ ("^" key "[[:space:]]*:")) {
        next
      }

      sub(/^[^:]*:[[:space:]]*/, "", line)
      line = trim(line)
      quote = substr(line, 1, 1)
      if (quote == "\"" || quote == sprintf("%c", 39)) {
        end = 0
        escaped = 0
        for (i = 2; i <= length(line); i++) {
          char = substr(line, i, 1)
          if (quote == "\"" && char == "\\" && !escaped) {
            escaped = 1
            continue
          }
          if (char == quote && !escaped) {
            end = i
            break
          }
          escaped = 0
        }
        if (end == 0) {
          exit 1
        }
        trailing = trim(substr(line, end + 1))
        if (trailing != "" && substr(trailing, 1, 1) != "#") {
          exit 1
        }
        line = substr(line, 2, end - 2)
      } else {
        sub(/[[:space:]]+#.*$/, "", line)
        line = trim(line)
      }
      print line
      exit
    }
  ' "$config_file"); then
    echo "ERROR: Unable to read '$key' from configuration file '$config_file'." >&2
    return 1
  fi

  printf '%s' "$value"
}

remote_branch_exists() {
  local remote="$1"
  local branch_ref="$2"
  local refs ref
  if ! refs=$(git ls-remote --heads "$remote" "$branch_ref"); then
    return 2
  fi

  while IFS=$'\t' read -r _ ref; do
    if [[ "$ref" == "$branch_ref" ]]; then
      return 0
    fi
  done <<<"$refs"
  return 1
}

ensure_pages_branch() {
  local branch="$pages_branch"
  if [[ -z "$branch" ]]; then
    branch=$(read_config_value pages-branch) || return 1
  fi
  branch=${branch:-gh-pages}

  local remote
  remote=$(read_config_value remote) || return 1
  remote=${remote:-origin}

  local branch_ref="refs/heads/$branch"
  if ! git check-ref-format "$branch_ref"; then
    echo "ERROR: Invalid publishing branch name '$branch'." >&2
    return 1
  fi

  local remote_branch_ref="refs/remotes/$remote/$branch"
  local lookup_status
  if remote_branch_exists "$remote" "$branch_ref"; then
    :
  else
    lookup_status=$?
    if [[ "$lookup_status" -ne 1 ]]; then
      echo "ERROR: Unable to check whether publishing branch '$branch' exists on '$remote'." >&2
      return "$lookup_status"
    fi

    echo "Publishing branch '$branch' does not exist; creating an empty branch..."
    local empty_tree empty_commit actor actor_id
    empty_tree=$(git mktree </dev/null) || return 1
    actor="${GITHUB_ACTOR:-github-actions[bot]}"
    actor_id="${GITHUB_ACTOR_ID:-41898282}"
    empty_commit=$(
      git -c user.name="$actor" \
        -c user.email="$actor_id+$actor@users.noreply.github.com" \
        commit-tree "$empty_tree" -m "Initialize $branch"
    ) || return 1

    if git push "$remote" "$empty_commit:$branch_ref"; then
      echo "Created publishing branch '$branch'."
    else
      local push_status=$?
      if remote_branch_exists "$remote" "$branch_ref"; then
        echo "Publishing branch '$branch' was created concurrently; continuing."
      else
        lookup_status=$?
        if [[ "$lookup_status" -ne 1 ]]; then
          echo "ERROR: Unable to verify publishing branch '$branch' after the push failed." >&2
        fi
        echo "ERROR: Unable to create publishing branch '$branch'. Check the repository's write permissions." >&2
        return "$push_status"
      fi
    fi
  fi

  git fetch --no-tags "$remote" "+$branch_ref:$remote_branch_ref"
}

main "$@"
