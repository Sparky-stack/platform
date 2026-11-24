#!/usr/bin/env node
// Merging the grouped "chore: release main" PR must tag every bumped component, also when only ONE is bumped (#313).
// Drives release-please's own code (the version release.yaml's action pin bundles) over release-please-config.json:
// for each package alone, and for the root together with each package, it builds the merged PR the way the merge
// plugin writes it (branch release-please--branches--main, body via PullRequestBody with useComponents) and asserts
// strategy.buildRelease() returns the expected tag: v<semver> for ".", <component>-v<semver> for the others.
// Usage: npm install --prefix "$dir" release-please@<version>; NODE_PATH="$dir/node_modules" node <this file> [repo]
'use strict';
const fs = require('fs');
const path = require('path');
const rp = require('release-please');
const {PullRequestBody} = require('release-please/build/src/util/pull-request-body');
const {Version} = require('release-please/build/src/version');
const {setLogger} = require('release-please/build/src/util/logger');

const repo = process.argv[2] || path.resolve(__dirname, '../..');
const workflow = fs.readFileSync(path.join(repo, '.github/workflows/release.yaml'), 'utf8');
const pin = /release-please-action@[0-9a-f]{40} # v(\d+)/.exec(workflow);
const expected = process.env.RELEASE_PLEASE_VERSION; // set by CI from the action pin's package-lock.json
let fails = 0;
const fail = msg => { console.error(`FAIL: ${msg}`); fails++; };
if (!pin) fail('release.yaml: googleapis/release-please-action is not pinned by SHA');
if (expected && rp.VERSION !== expected) fail(`release-please ${rp.VERSION} installed, action pin bundles ${expected}`);

const logs = [];
const quiet = () => (...a) => logs.push(a.join(' '));
setLogger({error: quiet(), warn: quiet(), info: quiet(), debug: quiet(), trace: quiet()});

const github = {
  repository: {owner: 'Sparky-stack', repo: 'platform', defaultBranch: 'main'},
  getFileJson: async f => JSON.parse(fs.readFileSync(path.join(repo, f), 'utf8')),
};

(async () => {
  const manifest = await rp.Manifest.fromManifest(github, 'main', 'release-please-config.json',
    '.release-please-manifest.json');
  const strategies = await manifest.getStrategiesByPath();
  const config = JSON.parse(fs.readFileSync(path.join(repo, 'release-please-config.json'), 'utf8'));
  const titlePattern = config['group-pull-request-title-pattern'];
  const bump = v => { const x = Version.parse(v); return new Version(x.major, x.minor + 1, 0); };
  const wantTag = (p, v) => p === '.' ? `v${v}` : `${config.packages[p].component}-v${v}`;

  const check = async paths => {
    const versions = Object.fromEntries(paths.map(p => [p, bump(manifest.releasedVersions[p].toString())]));
    const releaseData = [];
    for (const p of paths) {
      const component = await strategies[p].getComponent(); // what buildReleasePullRequest() writes into the body
      releaseData.push({component, version: versions[p], notes: `## [${versions[p]}] notes for ${p}`});
    }
    const pr = {
      headBranchName: 'release-please--branches--main', baseBranchName: 'main', number: 1,
      title: titlePattern.replace('${branch}', 'main'), labels: ['autorelease: pending'], files: [],
      body: new PullRequestBody(releaseData, {useComponents: true}).toString(), sha: 'abc123',
    };
    for (const p of paths) {
      logs.length = 0;
      const release = await strategies[p].buildRelease(pr, {groupPullRequestTitlePattern: titlePattern});
      const got = release && release.tag.toString();
      const want = wantTag(p, versions[p]);
      if (got !== want) fail(`grouped release of [${paths}]: ${p} tag ${got} != ${want} (${logs.filter(l => /component|match/.test(l)).join('; ')})`);
    }
  };

  const paths = Object.keys(config.packages);
  for (const p of paths) await check([p]);
  for (const p of paths.filter(p => p !== '.')) await check(['.', p]);
  if (fails) process.exit(1);
  console.log(`ok: ${paths.length} single + ${paths.length - 1} paired grouped releases tag as configured (release-please ${rp.VERSION})`);
})().catch(e => { console.error(e); process.exit(1); });
