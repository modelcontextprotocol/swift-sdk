#!/usr/bin/env node
// Scores a '--requirements <rev>' run the way 'conformance tier-check' does:
// a scored scenario passes when it has at least one SUCCESS check and no
// FAILURE check; a scenario without results fails.
//
// Usage: conformance-score.mjs --list <file> --role <server|client> --results <dir>
//   <file> is the output of 'conformance list --requirements <rev>'.
//
// Exit status: 0 when every scored scenario passes, 1 when one fails or the
// list names no scored scenario for the role, 2 on bad arguments.

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";

const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].slice(2)] = process.argv[i + 1];
if (!args.list || !["server", "client"].includes(args.role) || !args.results) {
  console.error("usage: conformance-score.mjs --list <file> --role <server|client> --results <dir>");
  process.exit(2);
}

function scoredScenarios(listFile, role) {
  const heading = role === "server" ? "Server scenarios" : "Client scenarios";
  const lines = readFileSync(listFile, "utf-8").split("\n");
  const start = lines.findIndex((line) => line.startsWith(heading));
  if (start === -1) return [];
  const names = [];
  for (const line of lines.slice(start + 1)) {
    const match = line.match(/^\s+-\s+(\S+)\s*$/);
    if (!match) break;
    names.push(match[1]);
  }
  return names;
}

function results(dir, role) {
  const byScenario = new Map();
  const walk = (path) => {
    for (const name of readdirSync(path)) {
      const child = join(path, name);
      if (statSync(child).isDirectory()) walk(child);
      else if (name === "checks.json") {
        let scenario = relative(dir, path).split(sep).join("/").replace(/-\d{4}-\d{2}-\d{2}T[\d-]+Z$/, "");
        if (role === "server") scenario = scenario.replace(/^server-/, "");
        byScenario.set(scenario, JSON.parse(readFileSync(child, "utf-8")));
      }
    }
  };
  if (existsSync(dir)) walk(dir);
  return byScenario;
}

const scored = scoredScenarios(args.list, args.role);
const byScenario = results(args.results, args.role);
const failing = scored.filter((scenario) => {
  const checks = byScenario.get(scenario) ?? [];
  return !(checks.some((c) => c.status === "SUCCESS") && !checks.some((c) => c.status === "FAILURE"));
});
const passed = scored.length - failing.length;
const rate = scored.length ? ((100 * passed) / scored.length).toFixed(1) : "0.0";
console.log(`Tier score (${args.role}): ${passed}/${scored.length} scored scenarios pass (${rate}%)`);
for (const scenario of failing) console.log(`  ✗ ${scenario}`);
if (scored.length === 0) console.error(`No scored ${args.role} scenarios in ${args.list}`);
process.exitCode = scored.length === 0 || failing.length > 0 ? 1 : 0;
