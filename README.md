# *chart-releaser* Action

A GitHub action to turn a GitHub project into a self-hosted Helm chart repo, using [helm/chart-releaser](https://github.com/helm/chart-releaser) CLI tool.

## Usage

### Pre-requisites

1. A GitHub repo containing a directory with your Helm charts (eg: `/charts`)
1. A GitHub branch called `gh-pages` to store the published charts. See `charts_repo_url` for alternatives
1. Create a workflow `.yml` file in your `.github/workflows` directory. An [example workflow](#example-workflow) is available below.
  For more information, reference the GitHub Help Documentation for [Creating a workflow file](https://help.github.com/en/articles/configuring-a-workflow#creating-a-workflow-file)

### Inputs

- `version`: The chart-releaser version to use (default: v1.2.1)
- `config`: Optional config file for chart-releaser. For more information on the config file, see the [documentation](https://github.com/helm/chart-releaser#config-file)
- `charts_dir`: The charts directory
- `charts_repo_url`: The GitHub Pages URL to the charts repo (default: `https://<owner>.github.io/<project>`)

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
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v2
        with:
          fetch-depth: 0

      - name: Configure Git
        run: |
          git config user.name "$GITHUB_ACTOR"
          git config user.email "$GITHUB_ACTOR@users.noreply.github.com"

      - name: Install Helm
        uses: azure/setup-helm@v1
        with:
          version: v3.4.0

      - name: Run chart-releaser
        uses: helm/chart-releaser-action@v1.2.1
        env:
          CR_TOKEN: "${{ secrets.GITHUB_TOKEN }}"
```

This uses [@helm/chart-releaser-action](https://www.github.com/helm/chart-releaser-action) to turn your GitHub project into a self-hosted Helm chart repo.
It does this – during every push to `main` – by checking each chart in your project, and whenever there's a new chart version, creates a corresponding [GitHub release](https://help.github.com/en/github/administering-a-repository/about-releases) named for the chart version, adds Helm chart artifacts to the release, and creates or updates an `index.yaml` file with metadata about those releases, which is then hosted on GitHub Pages

#### Example using custom config

`workflow.yml`:
```yaml
- name: Run chart-releaser
  uses: helm/chart-releaser-action@v1.2.0
  with:
    charts_dir: charts
    config: cr.yaml
    charts_repo_url: xxxxxx
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
