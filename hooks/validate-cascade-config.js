#!/usr/bin/env node
'use strict';

/**
 * PostToolUse hook on Write|Edit|MultiEdit.
 *
 * Flags PowerShell content that hand-builds a Dataverse cascade-configuration
 * object (a literal with Assign/Share/Unshare/Reparent keys together) instead
 * of going through Add-DataverseLookup's -Cascade ValidateSet (Referential /
 * ReferentialRestrictDelete / Parental).
 *
 * Why this matters enough for a dedicated check: "Referential" and "Parental"
 * differ ONLY in Delete behavior - Assign, Share, Unshare and Reparent are
 * NoCascade for both. A hand-built cascade object that gets even one of those
 * four wrong (set to Cascade instead of NoCascade) becomes parental-equivalent
 * to Dataverse, which allows at most one such relationship per entity - the
 * NEXT lookup created on that table then fails outright with an error that
 * doesn't obviously point back at the actual cause. This happened for real
 * while building the reference implementation this plugin generalizes from.
 *
 * Dataverse.psm1 itself is exempt: its $script:CascadePresets block is the
 * trusted, reviewed definition of the three presets, not something this hook
 * needs to flag.
 */

const path = require('node:path');

function readStdin() {
    return new Promise((resolve, reject) => {
        let data = '';
        process.stdin.setEncoding('utf8');
        process.stdin.on('data', (chunk) => { data += chunk; });
        process.stdin.on('end', () => resolve(data));
        process.stdin.on('error', reject);
    });
}

function extractTargets(input) {
    const toolInput = input.tool_input || {};
    const filePath = toolInput.file_path;
    if (!filePath) return [];

    if (typeof toolInput.content === 'string') return [{ filePath, content: toolInput.content }];
    if (typeof toolInput.new_string === 'string') return [{ filePath, content: toolInput.new_string }];
    if (Array.isArray(toolInput.edits)) {
        return toolInput.edits
            .filter((e) => typeof e.new_string === 'string')
            .map((e) => ({ filePath, content: e.new_string }));
    }
    return [];
}

// All four keys present within a short span suggests a hand-built cascade
// object rather than a reference to the named presets.
const CASCADE_KEYS = ['Assign', 'Share', 'Unshare', 'Reparent'];

function looksHandBuilt(content) {
    // Slide a window and check whether all four keys appear within it -
    // cheap approximation of "these four are being set together in one object."
    const windowSize = 400;
    for (let i = 0; i < content.length; i += 100) {
        const window = content.slice(i, i + windowSize);
        if (CASCADE_KEYS.every((key) => new RegExp(`\\b${key}\\s*=`, 'i').test(window))) {
            return true;
        }
    }
    return false;
}

async function main() {
    const raw = await readStdin();
    let input;
    try {
        input = JSON.parse(raw);
    } catch {
        process.exit(0);
    }

    const targets = extractTargets(input).filter(
        (t) => /\.psm?1$/i.test(t.filePath) && path.basename(t.filePath) !== 'Dataverse.psm1'
    );

    const problems = targets.filter((t) => looksHandBuilt(t.content)).map((t) => t.filePath);

    if (problems.length === 0) {
        process.exit(0);
    }

    console.error(
        'Cascade-configuration check failed.\n\n' +
        'The following file(s) appear to hand-build a cascade configuration ' +
        '(Assign/Share/Unshare/Reparent set directly) instead of using a named preset:\n' +
        problems.map((p) => `  - ${p}`).join('\n') +
        '\n\nUse Add-DataverseLookup -Cascade Referential|ReferentialRestrictDelete|Parental ' +
        'instead. Referential and Parental differ ONLY in Delete behavior - getting Assign/' +
        'Share/Unshare/Reparent wrong on a hand-built "Referential" relationship makes it ' +
        'parental-equivalent to Dataverse, which allows at most one such relationship per ' +
        'entity. The next lookup created on the same table then fails with an error that does ' +
        'not obviously point back at this cause.'
    );
    process.exit(2);
}

main();
