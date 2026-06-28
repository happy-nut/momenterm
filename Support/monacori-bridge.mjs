#!/usr/bin/env node
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

function json(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function fail(error) {
  const message = error instanceof Error ? error.stack || error.message : String(error);
  json({ ok: false, error: message });
  process.exitCode = 1;
}

function monacoriDist() {
  const candidates = [
    process.env.MONACORI_DIST,
    resolve(here, "../../monacori/dist"),
    resolve(here, "../monacori/dist"),
  ].filter(Boolean);

  for (const candidate of candidates) {
    if (existsSync(resolve(candidate, "build.js"))) {
      return candidate;
    }
  }

  throw new Error(
    [
      "Could not find monacori/dist.",
      "Set MONACORI_DIST=/absolute/path/to/monacori/dist or keep momenterm next to monacori.",
    ].join(" "),
  );
}

async function importDist(name) {
  return import(pathToFileURL(resolve(monacoriDist(), name)).href);
}

async function readStdinJson() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  return raw ? JSON.parse(raw) : {};
}

async function build(root, payload = {}) {
  const { buildDiffReview } = await importDist("build.js");
  const review = buildDiffReview({
    root,
    staged: false,
    includeUntracked: true,
    context: 100000,
    title: "monacori native review",
    watch: true,
    ignoreWhitespace: !!payload.ignoreWhitespace,
    lazyLoad: true,
    app: true,
  });

  json({
    ok: true,
    root,
    html: review.html,
    files: review.files,
    hunks: review.hunks,
    signature: review.signature,
    generatedAt: review.generatedAt,
    lazyBodies: review.lazyBodies || [],
    lazySourceData: review.lazySourceData || "[]",
    update: review.update || null,
  });
}

async function gitLog(root, payload) {
  const { readGitLog } = await importDist("git-log.js");
  json({ ok: true, value: readGitLog(root, { limit: payload.limit, skip: payload.skip }) });
}

async function commitDiff(root, payload) {
  const { readCommitDiff } = await importDist("git-log.js");
  json({ ok: true, value: payload.sha ? readCommitDiff(root, payload.sha) : null });
}

async function httpSend(payload) {
  const { performHttpRequest } = await importDist("server.js");
  json({ ok: true, value: await performHttpRequest(payload) });
}

async function main() {
  const [command, root] = process.argv.slice(2);
  const payload = await readStdinJson();

  if (command === "build") return build(root, payload);
  if (command === "git-log") return gitLog(root, payload);
  if (command === "commit-diff") return commitDiff(root, payload);
  if (command === "http-send") return httpSend(payload);

  throw new Error(`Unknown command: ${command || "(missing)"}`);
}

main().catch(fail);
