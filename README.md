# _chart-releaser_ Action

A GitHub action to turn a GitHub project into a self-hosted Helm chart repo, using [helm/chart-releaser](https://github.com/helm/chart-releaser) CLI tool.

## Usage

### Pre-requisites

1. A GitHub repo containing a directory with your Helm charts (default is a folder named `/charts`, if you want to
   maintain your charts in a different directory, you must include a `charts_dir` input in the workflow).
1. A GitHub branch called `gh-pages` to store the published charts.
1. In your repo, go to Settings/Pages. Change the `Source` `Branch` to `gh-pages`.
1. Create a workflow `.yml` file in your `.github/workflows` directory. An [example workflow](#example-workflow) is available below.
   For more information, reference the GitHub Help Documentation for [Creating a workflow file](https://help.github.com/en/articles/configuring-a-workflow#creating-a-workflow-file)

### Inputs

- `version`: The chart-releaser version to use (default: v1.7.0)
- `config`: Optional config file for chart-releaser. For more information on the config file, see the [documentation](https://github.com/helm/chart-releaser#config-file)
- `charts_dir`: The charts directory
- `skip_packaging`: This option, when populated, will skip the packaging step. This allows you to do more advanced packaging of your charts (for example, with the `helm package` command) before this action runs. This action will only handle the indexing and publishing steps.
- `skip_existing`: Skip package upload if release/tag already exists
- `skip_upload`: This option, when populated, will skip the upload step. This allows you to do more advanced uploading of your charts (for exemple with OCI based repositories) which doen't require the `index.yaml`.
- `mark_as_latest`: When you set this to `false`, it will mark the created GitHub release not as 'latest'.
- `packages_with_index`: When you set this to `true`, it will upload chart packages directly into publishing branch.
- `pages_branch`: Name of the branch to be used to push the index and artifacts. (default to: gh-pages but it is not set in the action it is a default value for the chart-releaser binary)
- `pages_index_path`: Path to the index file in the gh-pages branch. (default to: index.yaml but it is not set in the action)
- `index_path`: Path to the index file. (default to: .cr-index/index.yaml but it is not set in the action)

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
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

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

## Code of conduct

Participation in the Helm community is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
