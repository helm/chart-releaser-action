// Copyright The Helm Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import * as exec from '@actions/exec';
import * as io from '@actions/io';
import {cr, git, helm} from "./tools";

export class ChartReleaser {
    constructor(private readonly owner: string, private readonly repository: string,
                private readonly chartRepoUrl: string, private readonly token: string) {
        if (owner === "") {
            throw new Error("owner is required")
        }
        if (repository === "") {
            throw new Error("repository is required")
        }
        if (chartRepoUrl == "") {
            this.chartRepoUrl = `https://${this.owner}.github.io/${this.repository}`
        }
        if (token === "") {
            throw new Error("token is required")
        }
    }

    async execute(charts: Set<string>) {
        if (charts.size === 0) {
            console.log("Charts set is emtpy. Nothing to do.")
            return
        }

        await io.rmRF(".cr-release-packages");
        await io.mkdirP(".cr-release-packages");

        await io.rmRF(".cr-index");
        await io.mkdirP(".cr-index");

        for (const chart of charts) {
            await this.packageChart(chart)
        }

        await this.releaseCharts();
        await this.updateIndex();
    }

    private async packageChart(chart: string) {
        console.log(`Packacking chart '${chart}'...`);

        await helm("package", chart, "--destination", ".cr-release-packages", "--save=false", "--dependency-update");
    }

    private async releaseCharts() {
        console.log("Releasing charts...");

        await cr(this.token, "upload", "-o", this.owner, "-r", this.repository);
    }

    private async updateIndex() {
        console.log("Updating repo index...");

        await cr(this.token, "index", "-o", this.owner, "-r", this.repository, "-c", this.chartRepoUrl);

        await git("checkout", "gh-pages");

        await exec.exec("cp", ["--force", ".cr-index/index.yaml", "index.yaml"]);

        const actor = process.env["GITHUB_ACTOR"] || "";
        await git("config", "--local", "user.name", actor);
        await git("config", "--local", "user.email", "noreply@github.com");

        await git("add", "index.yaml");
        await git("commit", "--message='Update index.yaml'", "--signoff");

        const repoUrl = `https://x-access-token:${this.token}@github.com/${this.owner}/${this.repository}`;
        await git("push", repoUrl, "gh-pages");
    }
}
