// Copyright The Helm Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//   # You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
//   # WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//   # See the License for the specific language governing permissions and
// limitations under the License.

const spawn = require('child_process').spawn
const path = require("path");

const main = async () => {
    await new Promise((resolve, reject) => {
        const proc = spawn('bash', [path.join(__dirname, 'main.sh')], {stdio: 'inherit'})
        proc.on('close', resolve)
        proc.on('error', reject)
    })
}

main().catch(err => {
    console.error(err)
    console.error(err.stack)
    process.exit(-1)
})
