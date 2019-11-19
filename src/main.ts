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

import * as core from '@actions/core';
import {ChartReleaser} from "./cr";
import {git} from "./tools";

const ChartsDirInput = "charts-dir";
const ChartsRepoUrlInput = "charts-repo-url";
const TokenInput = "token";

export function createChartReleaser(): ChartReleaser {
    const ownerRepo = process.env["GITHUB_REPOSITORY"] || "";
    const split = ownerRepo.split("/");
    const owner = split[0];
    const repo = split[1];

    const chartsRepoUrl = core.getInput(ChartsRepoUrlInput);
    const token = core.getInput(TokenInput);
    return new ChartReleaser(owner, repo, chartsRepoUrl, token)
}

async function run() {
    try {
        const workspace = process.env["GITHUB_WORKSPACE"];
        if (workspace !== process.cwd()) {
            core.setFailed("action must be run in the workspace root");
            return
        }

        let chartsDir = core.getInput(ChartsDirInput);
        if (chartsDir === "") {
            chartsDir = "charts"
        }

        console.log("Looking up latest tag...");
        const tag = await findLatestTag();

        console.log(`Identifying changed charts since ${tag}...`)
        const charts = await findChangedCharts(chartsDir, tag);

        if (charts.size == 0) {
            console.log("Nothing to do. No chart changes detected.")
            return
        }

        const cr = createChartReleaser();
        await cr.execute(charts)
    } catch (error) {
        core.setFailed(error.message);
    }
}

async function findLatestTag(): Promise<string> {
    let tag: string;
    try {
        tag = await git("describe", "--tags", "--abbrev=0");
    } catch (ex) {
        console.log("No tag found in repo. Getting first commit instead...");
        tag = await git("rev-list", "--max-parents=0", "--first-parent", "HEAD");
    }
    return tag.trim()
}

export async function findChangedCharts(chartsDir: string, ref: string): Promise<Set<string>> {
    let changes = await git("diff", "--find-renames", "--name-only", ref, "--", chartsDir);
    const set = new Set<string>();

    changes = changes.trim();
    if (changes) {
        for (let change of changes.split("\n")) {
            const split = change.split("/");
            set.add(split[0] + "/" + split[1])
        }
    }
    return set
}

run();
