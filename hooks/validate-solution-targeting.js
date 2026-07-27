#!/usr/bin/env node
'use strict';

/**
 * PostToolUse hook on Write|Edit|MultiEdit.
 *
 * Flags PowerShell content that calls a Dataverse metadata-creating endpoint
 * directly (a raw Invoke-RestMethod POST to EntityDefinitions,
 * RelationshipDefinitions, GlobalOptionSetDefinitions, or savedqueries/roles)
 * without the MSCRM.SolutionUniqueName header anywhere in the same file.
 *
 * This does not (and cannot) guard live API calls made through
 * Dataverse.psm1's own functions - those already require -SolutionUniqueName
 * as a mandatory PowerShell parameter, a stronger guarantee than a hook could
 * add. What this catches is new code - a copy-pasted script, a bypass of the
 * module's safe wrappers - reintroducing the exact failure mode that shipped
 * this plugin in the first place: a component silently landing in whatever
 * solution the environment currently has selected as default.
 *
 * Dataverse.psm1 itself is exempt: it is the trusted, already-reviewed source
 * of the SolutionUniqueName mechanism, not something this hook needs to
 * police.
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
    // Normalize across Write (file_path/content), Edit (file_path/new_string),
    // and MultiEdit (file_path/edits[].new_string) tool-call shapes.
    const toolInput = input.tool_input || {};
    const filePath = toolInput.file_path;
    if (!filePath) return [];

    if (typeof toolInput.content === 'string') {
        return [{ filePath, content: toolInput.content }];
    }
    if (typeof toolInput.new_string === 'string') {
        return [{ filePath, content: toolInput.new_string }];
    }
    if (Array.isArray(toolInput.edits)) {
        return toolInput.edits
            .filter((e) => typeof e.new_string === 'string')
            .map((e) => ({ filePath, content: e.new_string }));
    }
    return [];
}

const METADATA_CREATE_ENDPOINT = /Invoke-(RestMethod|WebRequest)[^\n]*-Method\s+['"]?Post['"]?[^\n]*(EntityDefinitions|RelationshipDefinitions|GlobalOptionSetDefinitions|savedqueries|\broles\b)/is;
const SOLUTION_HEADER = /MSCRM\.SolutionUniqueName/i;

async function main() {
    const raw = await readStdin();
    let input;
    try {
        input = JSON.parse(raw);
    } catch {
        process.exit(0); // Can't parse - don't block on a hook-infrastructure problem.
    }

    const targets = extractTargets(input).filter(
        (t) => /\.psm?1$/i.test(t.filePath) && path.basename(t.filePath) !== 'Dataverse.psm1'
    );

    const problems = [];
    for (const target of targets) {
        if (METADATA_CREATE_ENDPOINT.test(target.content) && !SOLUTION_HEADER.test(target.content)) {
            problems.push(target.filePath);
        }
    }

    if (problems.length === 0) {
        process.exit(0);
    }

    console.error(
        'Solution-targeting check failed.\n\n' +
        `The following file(s) call a Dataverse metadata-creating endpoint directly ` +
        `(EntityDefinitions / RelationshipDefinitions / GlobalOptionSetDefinitions / ` +
        `savedqueries / roles) without an MSCRM.SolutionUniqueName header anywhere in the file:\n` +
        problems.map((p) => `  - ${p}`).join('\n') +
        '\n\nPrefer calling the functions in Dataverse.psm1 (New-DataverseTable, ' +
        'Add-DataverseColumn, Add-DataverseLookup, etc.) instead of a raw Invoke-RestMethod ' +
        'call - they require -SolutionUniqueName as a mandatory parameter and send it correctly. ' +
        'If a raw call is genuinely needed, add the MSCRM.SolutionUniqueName header explicitly.'
    );
    process.exit(2);
}

main();
