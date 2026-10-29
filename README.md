# _chart-releaser_ Action

A GitHub action to turn a GitHub project into a self-hosted Helm chart repo, using [helm/chart-releaser](https://github.com/helm/chart-releaser) CLI tool.

## Usage

### Pre-requisites

1. A GitHub repo containing a directory with your Helm charts (default is a folder named `/charts`, if you want to
   maintain your charts in a different directory, you must include a `charts_dir` input in the workflow).
1. A GitHub branch called `gh-pages` to store the index and, optionally, chart packages. See [Publishing branch setup](#publishing-branch-setup).
1. In your repo, go to Settings/Pages. Change the `Source` `Branch` to `gh-pages`.
1. Create a workflow `.yml` file in your `.github/workflows` directory. An [example workflow](#example-workflow) is available below.
   For more information, reference the GitHub Help Documentation for [Creating a workflow file](https://help.github.com/en/articles/configuring-a-workflow#creating-a-workflow-file)

#### Publishing branch setup

Create the publishing branch separately from the source branch so it does not inherit source files, workflows, or `.gitignore` rules. For example, create an empty orphan branch in a temporary worktree:

```bash
git worktree add --detach ../chart-releaser-pages HEAD
cd ../chart-releaser-pages
git switch --orphan gh-pages
git commit --allow-empty -m "Initialize gh-pages"
git push origin gh-pages
cd -
git worktree remove ../chart-releaser-pages
```

Run this once, before the first release. If you configure `pages_branch`, use that branch name instead of `gh-pages`.

When `packages_with_index: true` is enabled, the action commits `.tgz` chart packages alongside `index.yaml`. The publishing branch's `.gitignore` must allow those files. In particular, remove an inherited `*.tgz` rule if Git reports `The following paths are ignored by one of your .gitignore files`. You can still ignore `.tgz` files on the source branch; its ignore rules do not apply to a separate publishing branch.

#### Checkout credentials

Chart-releaser uses Git worktrees to publish the index and chart packages. If you use `actions/checkout@v6`, use v6.0.1 or later: v6.0.0 moved persisted credentials to a separate file without making them available in worktrees. This was fixed in [actions/checkout#2327](https://github.com/actions/checkout/pull/2327). The example below uses v7, which includes the fix.

If publishing fails with `fatal: could not read Username for 'https://github.com': No such device or address`, check the checkout version and keep `persist-credentials: true` enabled. Setting `CR_TOKEN` alone does not persist checkout credentials for Git worktrees. The workflow also needs `contents: write` permission. If you use a custom token, pass it to both checkout's `token` input and `CR_TOKEN`.

### Inputs

- `version`: The chart-releaser version to use (default: v1.9.0)
- `config`: Optional config file for chart-releaser. For more information on the config file, see the [documentation](https://github.com/helm/chart-releaser#config-file)
- `charts_dir`: The charts directory
- `skip_packaging`: This option, when populated, will skip the packaging step. This allows you to do more advanced packaging of your charts (for example, with the `helm package` command) before this action runs. This action will only handle the indexing and publishing steps.
- `skip_existing`: Skip package upload if release/tag already exists
- `skip_upload`: This option, when populated, will skip the upload step. This allows you to do more advanced uploading of your charts (for example with OCI based repositories) which doesn't require the `index.yaml`.
- `mark_as_latest`: When set to `false`, the created GitHub release will not be marked as the "latest" release on the repository's releases page.
- `match_tags`: The glob to use to filter Git tags, usually used with the `CR_RELEASE_NAME_TEMPLATE` environment variable (default: all tags)
- `packages_with_index`: When you set this to `true`, it will upload chart packages directly into publishing branch.
- `pages_branch`: Name of the branch to be used to push the index and artifacts. (default to: gh-pages but it is not set in the action it is a default value for the chart-releaser binary)
- `oci_registry_url`: OCI registry URL (e.g. `oci://ghcr.io/myorg/charts`). When set, the action additionally pushes each packaged chart to this OCI registry via `cr push`. For authentication, the recommended approach is to run [`docker/login-action`](https://github.com/docker/login-action) before this action so credentials are placed in the local registry credential store; alternatively pass `oci_username` / `oci_password` explicitly.
- `oci_username`: Username for OCI registry authentication. Falls back to the local registry credential store (e.g. `~/.docker/config.json` populated by `docker/login-action`, `helm registry login`, or `docker login`) when unset.
- `oci_password`: Password or token for OCI registry authentication. Falls back to the local registry credential store when unset.

### Outputs

- `changed_charts`: A comma-separated list of charts that were released on this run. Will be an empty string if no updates were detected, will be unset if `--skip_packaging` is used: in the latter case your custom packaging step is responsible for setting its own outputs if you need them.
- `chart_version`: The version of the most recently generated charts; will be set even if no charts have been updated since the last run.

### Environment variables

- `CR_TOKEN` (required): The GitHub token of this repository (`${{ secrets.GITHUB_TOKEN }}`)

For more information on environment variables, see the [documentation](https://github.com/helm/chart-releaser#environment-variables).

### Example Workflow

Create a workflow (eg: `.github/workflows/release.yml`):

```yaml
name: Release Charts

on:
  push:
    branches:
      - main

jobs:
  release:
    # depending on default permission settings for your org (contents being read-only or read-write for workloads), you will have to add permissions
    # see: https://docs.github.com/en/actions/security-guides/automatic-token-authentication#modifying-the-permissions-for-the-github_token
    permissions:
      contents: write
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v7
        with:
          fetch-depth: 0
          persist-credentials: true

      - name: Configure Git
        run: |
          git config user.name "$GITHUB_ACTOR"
          git config user.email "$GITHUB_ACTOR@users.noreply.github.com"

      - name: Run chart-releaser
        uses: helm/chart-releaser-action@v1.7.0
        env:
          CR_TOKEN: "${{ secrets.GITHUB_TOKEN }}"
```

This uses [@helm/chart-releaser-action](https://www.github.com/helm/chart-releaser-action) to turn your GitHub project into a self-hosted Helm chart repo.
It does this – during every push to `main` – by checking each chart in your project, and whenever there's a new chart version, creates a corresponding [GitHub release](https://help.github.com/en/github/administering-a-repository/about-releases) named for the chart version, adds Helm chart artifacts to the release, and creates or updates an `index.yaml` file with metadata about those releases, which is then hosted on GitHub Pages. You do not need an `index.yaml` file in `main` at all because it is managed in the `gh-pages` branch.

#### Example using custom config

`workflow.yml`:

```yaml
- name: Run chart-releaser
  uses: helm/chart-releaser-action@v1.7.0
  with:
    charts_dir: charts
    config: cr.yaml
  env:
    CR_TOKEN: "${{ secrets.GITHUB_TOKEN }}"
```

`cr.yaml`:

```yaml
owner: myaccount
git-base-url: https://api.github.com/
```

For options see [config-file](https://github.com/helm/chart-releaser#config-file).

#### Custom index locations

Use the `config` input to set the CLI's `index-path` and `pages-index-path` options:

```yaml
- name: Run chart-releaser
  uses: helm/chart-releaser-action@v1.8.0
  with:
    config: cr.yaml
    pages_branch: gh-pages
  env:
    CR_TOKEN: "${{ secrets.GITHUB_TOKEN }}"
```

`cr.yaml`:

```yaml
index-path: site/static/index.yaml
pages-index-path: docs/index.yaml
```

`index-path` is the generated file in the workflow checkout, which a later site-build step can use. `pages-index-path` is the index location relative to the publishing branch; the example publishes `docs/index.yaml` on `gh-pages`. Set `pages_branch` to another existing branch if your documentation source lives there, and use a path such as `docs/static/index.yaml` if needed. Both paths should end in `index.yaml`. If another workflow rebuilds the published site, include the index in its build output so it is preserved.

For a custom publishing subdirectory, leave `packages_with_index` disabled (the default), so chart URLs point to GitHub release assets. When `packages_with_index: true` is used, the CLI stores chart archives at the publishing branch root; keep `pages-index-path: index.yaml` so its relative package URLs resolve correctly. You can still customize the local `index-path`.

#### Example pushing to an OCI registry

When `oci_registry_url` is set, the action pushes each packaged chart to the OCI registry in addition to (or instead of) the GitHub Pages flow. The recommended way to authenticate is by running [`docker/login-action`](https://github.com/docker/login-action) earlier in the job so the registry credential store is populated; `cr push` then picks them up automatically.

```yaml
- name: Log in to the OCI registry
  uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}

- name: Run chart-releaser
  uses: helm/chart-releaser-action@v1.7.0
  with:
    oci_registry_url: oci://ghcr.io/${{ github.repository_owner }}/charts
  env:
    CR_TOKEN: "${{ secrets.GITHUB_TOKEN }}"
```

If you prefer to pass credentials directly to the action instead of using `docker/login-action`, set the `oci_username` and `oci_password` inputs.

## Code of conduct

Participation in the Helm community is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
