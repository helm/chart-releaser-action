import * as exec from '@actions/exec';
import * as io from '@actions/io';
import fs from 'fs';

export async function git(...args: string[]): Promise<string> {
    let output = '';

    const options = {};
    // @ts-ignore
    options.listeners = {
        stdout: (data: Buffer) => {
            output += data.toString();
        }
    };

    await exec.exec("git", args, options);
    return output
}

export async function helm(...args: string[]) {
    const home = process.env["HOME"];
    const workspace = process.env["GITHUB_WORKSPACE"];

    const dockerArgs = [
        "run",
        "--interactive",
        "--rm",
        "--volume", `${home}/.helm:/root/.helm`,
        "--volume", `${workspace}:/workdir`,
        "--workdir", "/workdir",
        "lachlanevenson/k8s-helm:v2.16.1"
    ];

    if (!fs.existsSync(`${home}/.helm`)) {
        await io.mkdirP(`${home}/.helm`);
        await exec.exec("docker", dockerArgs.concat("init", "--client-only"))
    }
    await exec.exec("docker", dockerArgs.concat(args));
}

export async function cr(token: string, ...args: string[]) {
    const workspace = process.env["GITHUB_WORKSPACE"];

    const options = {};
    // @ts-ignore
    options.env = {
        CR_TOKEN: token
    };

    const dockerArgs = [
        "run",
        "--interactive",
        "--rm",
        "--env", "CR_TOKEN",
        "--volume", `${workspace}:/workdir`,
        "--workdir", "/workdir",
        "quay.io/helmpack/chart-releaser:v0.2.3"
    ];

    await exec.exec("docker", dockerArgs.concat("cr", args), options);
}
