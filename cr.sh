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

DEFAULT_CHART_RELEASER_VERSION=v1.0.0-beta.1

show_help() {
cat << EOF
Usage: $(basename "$0") <options>

    -h, --help               Display help
    -v, --version            The chart-releaser version to use (default: v1.0.0-beta.1)"
    -d, --charts-dir         The charts directory (defaut: charts)
    -u, --charts-repo-url    The GitHub Pages URL to the charts repo (default: https://<owner>.github.io/<repo>)
    -o, --owner              The repo owner
    -r, --repo               The repo name
EOF
}

main() {
    local version="$DEFAULT_CHART_RELEASER_VERSION"
    local charts_dir=charts
    local owner=
    local repo=
    local charts_repo_url=

    parse_command_line "$@"

    echo "$repo"
    local repo_root
    repo_root=$(git rev-parse --show-toplevel)
    pushd "$repo_root" > /dev/null

    echo 'Looking up latest tag...'
    local latest_tag
    latest_tag=$(lookup_latest_tag)

    echo "Discovering changed charts since '$latest_tag'..."
    local changed_charts=()
    readarray -t changed_charts <<< "$(lookup_changed_charts "$latest_tag")"

    if [[ -n "${changed_charts[*]}" ]]; then
        install_chart_releaser

        rm -rf .cr-release-packages
        mkdir -p .cr-release-packages

        rm -rf .cr-index
        mkdir -p .cr-index

        for chart in "${changed_charts[@]}"; do
            if [[ -d "$chart" ]]; then
                package_chart "$chart"
            else
                echo "Chart '$chart' no longer exists in repo. Skipping it..."
            fi
        done

        release_charts
        update_index
    else
        echo "Nothing to do. No chart changes detected."
    fi

    popd > /dev/null
}

parse_command_line() {
    while :; do
        case "${1:-}" in
            -h|--help)
                show_help
                exit
                ;;
            -v|--version)
                if [[ -n "${2:-}" ]]; then
                    version="$2"
                    shift
                else
                    echo "ERROR: '-v|--version' cannot be empty." >&2
                    show_help
                    exit 1
                fi
                ;;
            -d|--charts-dir)
                if [[ -n "${2:-}" ]]; then
                    charts_dir="$2"
                    shift
                else
                    echo "ERROR: '-d|--charts-dir' cannot be empty." >&2
                    show_help
                    exit 1
                fi
                ;;
            -u|--charts-repo-url)
                if [[ -n "${2:-}" ]]; then
                    charts_repo_url="$2"
                    shift
                else
                    echo "ERROR: '-u|--charts-repo-url' cannot be empty." >&2
                    show_help
                    exit 1
                fi
                ;;
            -o|--owner)
                if [[ -n "${2:-}" ]]; then
                    owner="$2"
                    shift
                else
                    echo "ERROR: '--owner' cannot be empty." >&2
                    show_help
                    exit 1
                fi
                ;;
            -r|--repo)
                if [[ -n "${2:-}" ]]; then
                    repo="$2"
                    shift
                else
                    echo "ERROR: '--repo' cannot be empty." >&2
                    show_help
                    exit 1
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

    if [[ -z "$charts_repo_url" ]]; then
        charts_repo_url="https://$owner.github.io/$repo"
    fi
}

install_chart_releaser() {
    echo "Installing chart-releaser..."

    curl -sSLo cr.tar.gz "https://github.com/helm/chart-releaser/releases/download/$version/chart-releaser_${version#v}_linux_amd64.tar.gz"
    tar -xzf cr.tar.gz
    sudo mv cr /usr/local/bin/cr
}

lookup_latest_tag() {
    git fetch --tags > /dev/null 2>&1

    if ! git describe --tags --abbrev=0 2> /dev/null; then
        git rev-list --max-parents=0 --first-parent HEAD
    fi
}

filter_charts() {
    while read chart; do
        [[ ! -d "$chart" ]] && continue
        local file="$chart/Chart.yaml"
        if [[ -f "$file" ]]; then
            echo $chart
        else
           echo "WARNING: $file is missing, assuming that '$chart' is not a Helm chart. Skipping." 1>&2
        fi
    done
}

lookup_changed_charts() {
    local commit="$1"

    local changed_files
    changed_files=$(git diff --find-renames --name-only "$commit" -- "$charts_dir")

    local fields
    if [[ "$charts_dir" == '.' ]]; then
        fields='1'
    else
        fields='1,2'
    fi

    cut -d '/' -f "$fields" <<< "$changed_files" | uniq | filter_charts
}

package_chart() {
    local chart="$1"

    echo "Packaging chart '$chart'..."
    helm package "$chart" --destination .cr-release-packages --dependency-update
}

release_charts() {
    echo 'Releasing charts...'
    cr upload -o "$owner" -r "$repo"
}

update_index() {
    echo 'Updating charts repo index...'

    set -x

    cr index -o "$owner" -r "$repo" -c "$charts_repo_url"

    gh_pages_worktree=$(mktemp -d)

    git worktree add "$gh_pages_worktree" gh-pages

    cp --force .cr-index/index.yaml "$gh_pages_worktree/index.yaml"

    pushd "$gh_pages_worktree" > /dev/null

    git add index.yaml
    git commit --message="Update index.yaml" --signoff

    local repo_url="https://x-access-token:$GITHUB_TOKEN@github.com/$owner/$repo"
    git push "$repo_url" gh-pages

    popd > /dev/null
}

main "$@"
