/**
 * SessionStart hook: warns once per session if the installed plugin is
 * behind origin/main. Adapted from microsoft/power-platform-skills'
 * check-version.js pattern (plugins/model-apps/scripts/check-version.js),
 * ported from a per-skill instruction line to a hook, since this repo's
 * own stated principle is that enforcement belongs in hooks, not in
 * something the model has to remember to run (see "As-built architecture"
 * in the wiki project note).
 *
 * Real incident this prevents: on 2026-07-28, .claude-plugin/plugin.json's
 * version sat hardcoded at 0.1.0 since the first scaffold commit, so
 * Claude Code's marketplace update never detected that new skills existed
 * locally to install. This hook surfaces the same drift from the other
 * direction — an installed copy silently behind the source repo.
 *
 * Never blocks a session: any error is swallowed and the hook exits 0.
 */

const path = require('node:path');
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');

function compareSemver(localVersion, remoteVersion) {
  const localParts = localVersion.split('.').map(Number);
  const remoteParts = remoteVersion.split('.').map(Number);
  for (let index = 0; index < 3; index++) {
    if ((remoteParts[index] || 0) > (localParts[index] || 0)) return 1;
    if ((remoteParts[index] || 0) < (localParts[index] || 0)) return -1;
  }
  return 0;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function main() {
  const root = process.env.PLUGIN_ROOT || process.env.CLAUDE_PLUGIN_ROOT;
  if (!root) return;

  const pluginJsonPath = path.join(root, '.claude-plugin', 'plugin.json');
  if (!fs.existsSync(pluginJsonPath)) return;

  const localPlugin = readJson(pluginJsonPath);
  if (!localPlugin.version) return;

  try {
    execFileSync('git', ['-C', root, 'fetch', 'origin', 'main', '--quiet'], {
      timeout: 10000,
      stdio: ['ignore', 'ignore', 'ignore'],
    });
  } catch {
    // A stale local origin/main is still useful when offline.
  }

  let remotePlugin;
  try {
    const content = execFileSync(
      'git',
      ['-C', root, 'show', 'origin/main:.claude-plugin/plugin.json'],
      { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] }
    );
    remotePlugin = JSON.parse(content);
  } catch {
    return;
  }
  if (!remotePlugin.version) return;

  if (compareSemver(localPlugin.version, remotePlugin.version) > 0) {
    console.log(
      `Plugin update available: ${localPlugin.name} ${localPlugin.version} -> ${remotePlugin.version}.\n` +
        `Run:\n  claude plugin marketplace update dataverse-schema-architect\n  claude plugin update dataverse-schema-architect@dataverse-schema-architect`
    );
  }
}

try {
  main();
} catch {
  // Version checks must never block a session.
}
