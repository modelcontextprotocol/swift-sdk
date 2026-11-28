#!/usr/bin/env node
// Generates a conformance expected-failures file from harness results.
//
// Usage: conformance-baseline.mjs --leg <label> --out <file>
//          [--server <results-dir> --server-log <harness-log>]
//          [--client <results-dir> --client-log <harness-log>]
//
// A role whose results directory is omitted keeps its entries from the
// existing <file>. Every FAILURE or WARNING check becomes a
// '<scenario>:<check-id>' entry, so the passing checks of a partly failing
// scenario stay enforced. A scenario that failed without writing a failing
// check (the harness log summary marks it failed) becomes a bare '<scenario>'.

import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, relative, sep } from "node:path";

const HEADERS = {
  default: [
    "Expected failures for the bare '--suite all' leg: every scenario shipped",
    "with the pinned harness, each at the harness's default wire. This is the",
    "only leg that reaches extension-tagged scenarios (tasks-*, the sep-2640-*",
    "skills scenarios and the auth/ extensions).",
  ],
  "2025-11-25": [
    "Expected failures at the 2025-11-25 wire ('--suite all --spec-version",
    "2025-11-25'): the stateful initialize handshake.",
  ],
  "2026-07-28": [
    "Expected failures at the 2026-07-28 wire ('--suite all --spec-version",
    "2026-07-28'): stateless requests with per-request _meta.",
  ],
};

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key?.startsWith("--") || value === undefined) {
      throw new Error(`invalid arguments near '${key ?? ""}'`);
    }
    args[key.slice(2)] = value;
  }
  if (!args.leg || !args.out) throw new Error("--leg and --out are required");
  if (!HEADERS[args.leg]) throw new Error(`unknown leg '${args.leg}'`);
  return args;
}

function findChecks(dir) {
  const found = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) found.push(...findChecks(path));
    else if (name === "checks.json") found.push(path);
  }
  return found;
}

// Results live in '<dir>/[server-]<scenario>-<ISO timestamp>/checks.json';
// auth scenarios add one directory level ('auth/<name>-<timestamp>').
function scenarioName(resultsDir, checksPath, role) {
  const parent = relative(resultsDir, checksPath).split(sep).slice(0, -1).join("/");
  let name = parent.replace(/-\d{4}-\d{2}-\d{2}T[\d-]+Z$/, "");
  if (role === "server") name = name.replace(/^server-/, "");
  return name;
}

// Scenarios the harness summary reports as failing: '✗ <scenario>: ...'.
function summaryFailures(logPath) {
  if (!logPath) return [];
  if (!existsSync(logPath)) throw new Error(`harness log not found: ${logPath}`);
  const failed = [];
  for (const line of readFileSync(logPath, "utf-8").split("\n")) {
    const match = line.match(/^✗ (\S+): \d+ passed, [1-9]\d* failed/);
    if (match) failed.push(match[1]);
  }
  return failed;
}

function failingEntries(resultsDir, logPath, role) {
  if (!existsSync(resultsDir)) throw new Error(`results directory not found: ${resultsDir}`);
  const files = findChecks(resultsDir);
  if (files.length === 0) throw new Error(`no checks.json under ${resultsDir}`);
  const entries = new Set();
  const withFailingChecks = new Set();
  for (const file of files) {
    const scenario = scenarioName(resultsDir, file, role);
    const checks = JSON.parse(readFileSync(file, "utf-8"));
    for (const check of checks) {
      if (check.status === "FAILURE" || check.status === "WARNING") {
        withFailingChecks.add(scenario);
        entries.add(`${scenario}:${check.id}`);
      }
    }
  }
  for (const scenario of summaryFailures(logPath)) {
    if (!withFailingChecks.has(scenario)) entries.add(scenario);
  }
  return [...entries].sort();
}

function existingEntries(file, role) {
  if (!existsSync(file)) return [];
  const lines = readFileSync(file, "utf-8").split("\n");
  const entries = [];
  let current = null;
  for (const line of lines) {
    const section = line.match(/^(server|client):/);
    if (section) {
      current = section[1];
      continue;
    }
    const item = line.match(/^\s+-\s+"?([^"]+)"?\s*$/);
    if (item && current === role) entries.push(item[1]);
  }
  return entries;
}

function render(leg, sections) {
  const out = [
    ...HEADERS[leg].map((l) => `# ${l}`),
    "#",
    "# Generated; do not edit. Regenerate with:",
    `#   scripts/run-conformance.sh${leg === "default" ? "" : ` --spec-version ${leg}`} --mode both --update-baseline`,
    "#",
    "# Entries are '<scenario>:<check-id>', or '<scenario>' for a scenario that",
    "# failed without producing a failing check. The harness fails a run on any",
    "# unlisted failure and on any listed entry that now passes.",
  ];
  for (const role of ["server", "client"]) {
    const entries = sections[role];
    if (entries.length === 0) {
      out.push(`${role}: []`);
    } else {
      out.push(`${role}:`);
      for (const entry of entries) out.push(`  - "${entry}"`);
    }
  }
  return out.join("\n") + "\n";
}

try {
  const args = parseArgs(process.argv.slice(2));
  const sections = {};
  for (const role of ["server", "client"]) {
    sections[role] = args[role]
      ? failingEntries(args[role], args[`${role}-log`], role)
      : existingEntries(args.out, role);
  }
  writeFileSync(args.out, render(args.leg, sections));
  console.log(`wrote ${args.out}: ${sections.server.length} server, ${sections.client.length} client`);
} catch (error) {
  console.error(`conformance-baseline: ${error.message}`);
  process.exit(1);
}
