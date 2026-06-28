#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const monacoriRoot = process.env.MONACORI_REPO || path.resolve(root, "../monacori");
const monacoriBuild = path.join(monacoriRoot, "dist/build.js");
const out = path.join(root, ".build/debug");
const dumpBin = path.join(out, "momenterm-ab-parity-dump");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "momenterm-ab-parity-"));
const failures = [];

function run(command, args, options = {}) {
  return execFileSync(command, args, {
    cwd: options.cwd || root,
    encoding: options.encoding || "utf8",
    maxBuffer: options.maxBuffer || 100 * 1024 * 1024,
    stdio: options.stdio || "pipe"
  });
}

function note(name, ok, detail = "") {
  if (ok) {
    console.log(`ok - ${name}`);
  } else {
    console.error(`not ok - ${name}${detail ? `: ${detail}` : ""}`);
    failures.push(`${name}${detail ? `: ${detail}` : ""}`);
  }
}

function write(file, content) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
}

function initRepo(name) {
  const dir = path.join(tmp, name);
  fs.mkdirSync(dir, { recursive: true });
  run("git", ["init", "-q"], { cwd: dir });
  run("git", ["config", "user.email", "ab-parity@example.com"], { cwd: dir });
  run("git", ["config", "user.name", "AB Parity"], { cwd: dir });
  write(path.join(dir, "README.md"), "# fixture\n");
  write(path.join(dir, ".gitignore"), ".monacori/\n");
  run("git", ["add", "."], { cwd: dir });
  run("git", ["commit", "-q", "-m", "base"], { cwd: dir });
  return dir;
}

function scenarioModified() {
  const dir = initRepo("modified");
  write(path.join(dir, "src/app.ts"), "export function add(a: number, b: number) {\n  return a + b;\n}\n");
  run("git", ["add", "."], { cwd: dir });
  run("git", ["commit", "-q", "-m", "add ts"], { cwd: dir });
  write(path.join(dir, "src/app.ts"), "export function add(a: number, b: number) {\n  return a + b + 1;\n}\n");
  return dir;
}

function scenarioStaged() {
  const dir = initRepo("staged");
  write(path.join(dir, "src/staged.js"), "export const value = 1;\n");
  run("git", ["add", "."], { cwd: dir });
  run("git", ["commit", "-q", "-m", "add staged fixture"], { cwd: dir });
  write(path.join(dir, "src/staged.js"), "export const value = 2;\n");
  run("git", ["add", "src/staged.js"], { cwd: dir });
  return dir;
}

function scenarioUntrackedText() {
  const dir = initRepo("untracked-text");
  write(path.join(dir, "notes/new.md"), "# New note\n\n- one\n- two\n");
  return dir;
}

function scenarioUntrackedBinary() {
  const dir = initRepo("untracked-binary");
  fs.writeFileSync(path.join(dir, "large.bin"), Buffer.alloc(500_001, 0));
  return dir;
}

function scenarioSourceAndEnv() {
  const dir = initRepo("source-env");
  write(path.join(dir, "data/table.csv"), "name,count\nalpha,1\nbeta,2\n");
  write(path.join(dir, "api/request.http"), "GET https://example.test\n");
  write(path.join(dir, "http-client.env.json"), JSON.stringify({ dev: { host: "example.test", port: 443, secure: true } }, null, 2));
  write(path.join(dir, "http-client.private.env.json"), JSON.stringify({ dev: { host: "private.example.test", token: "secret" } }, null, 2));
  write(path.join(dir, ".monacori/plan.md"), "# Plan\n\nNative parity item.\n");
  run("git", ["add", "data/table.csv", "api/request.http", "http-client.env.json", "http-client.private.env.json"], { cwd: dir });
  run("git", ["commit", "-q", "-m", "add source env"], { cwd: dir });
  write(path.join(dir, "data/table.csv"), "name,count\nalpha,1\nbeta,3\n");
  return dir;
}

function scenarioRenameDeleteImage() {
  const dir = initRepo("rename-delete-image");
  write(path.join(dir, "src/old-name.swift"), "func oldName() -> Int {\n  return 1\n}\n");
  write(path.join(dir, "src/remove-me.txt"), "delete me\n");
  fs.writeFileSync(path.join(dir, "pixel.png"), Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=", "base64"));
  run("git", ["add", "."], { cwd: dir });
  run("git", ["commit", "-q", "-m", "add rename delete image fixtures"], { cwd: dir });
  run("git", ["mv", "src/old-name.swift", "src/new-name.swift"], { cwd: dir });
  write(path.join(dir, "src/new-name.swift"), "func newName() -> Int {\n  return 2\n}\n");
  fs.rmSync(path.join(dir, "src/remove-me.txt"));
  return dir;
}

function compileDump() {
  fs.mkdirSync(out, { recursive: true });
  run("swiftc", [
    "-o", dumpBin,
    path.join(root, "Sources/Momenterm/Errors.swift"),
    path.join(root, "Sources/Momenterm/Shell.swift"),
    path.join(root, "Sources/Momenterm/NativeGitClient.swift"),
    path.join(root, "Sources/Momenterm/NativeReviewTypes.swift"),
    path.join(root, "Sources/Momenterm/UnifiedDiffParser.swift"),
    path.join(root, "Sources/Momenterm/NativeHTMLRenderer.swift"),
    path.join(root, "Sources/Momenterm/NativeSourceCollector.swift"),
    path.join(root, "Sources/Momenterm/NativeHttpEnvironmentReader.swift"),
    path.join(root, "Sources/Momenterm/NativeReviewCore.swift"),
    path.join(root, "Sources/ABParityDump/main.swift"),
    "-framework", "Foundation"
  ]);
}

function asObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function sorted(value) {
  return [...value].sort((a, b) => String(a).localeCompare(String(b)));
}

function fileStates(review) {
  const update = asObject(review.update);
  return (update.fileStates || [])
    .map((item) => ({ path: item.path, signature: item.signature }))
    .sort((a, b) => a.path.localeCompare(b.path));
}

function sourceMeta(review) {
  const update = asObject(review.update);
  return (update.sourceFilesMeta || [])
    .map((file) => ({
      path: file.path,
      name: file.name,
      language: file.language,
      size: file.size,
      changed: file.changed,
      embedded: file.embedded,
      changedLines: file.changedLines || [],
      signature: file.signature,
      skippedReason: file.skippedReason || "",
      image: file.image || "",
      vcs: file.vcs || ""
    }))
    .sort((a, b) => a.path.localeCompare(b.path));
}

function sourceDataPaths(review) {
  const raw = review.lazySourceData || "[]";
  const files = JSON.parse(raw);
  return sorted(files.map((file) => file.path));
}

function lazySourceContract(review) {
  const raw = review.lazySourceData || "[]";
  const files = JSON.parse(raw);
  return files
    .map((file) => ({
      path: file.path,
      name: file.name,
      language: file.language,
      size: file.size,
      changed: file.changed,
      embedded: file.embedded,
      changedLines: file.changedLines || [],
      signature: file.signature,
      content: file.content || "",
      skippedReason: file.skippedReason || "",
      image: file.image || "",
      vcs: file.vcs || ""
    }))
    .sort((a, b) => a.path.localeCompare(b.path));
}

function markerContract(html) {
  return {
    activityRail: html.includes("activity-rail"),
    quickOpen: html.includes("quick-open"),
    settings: html.includes("settings-modal"),
    sourceViewer: html.includes("source-viewer"),
    history: html.includes("history-view") || html.includes("history-viewer"),
    terminal: html.includes("terminal-panel"),
    viewed: html.includes("diff-viewed-toggle"),
    syntax: html.includes("hljs") || (html.includes("tok-keyword") && html.includes("highlightCode"))
  };
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort((a, b) => a.localeCompare(b)).map((key) => [key, stable(value[key])]));
  }
  return value;
}

function equalJSON(left, right) {
  return JSON.stringify(stable(left)) === JSON.stringify(stable(right));
}

function compareScenario(name, monacori, momenterm) {
  note(`${name}: file count`, monacori.files === momenterm.files, `${monacori.files} != ${momenterm.files}`);
  note(`${name}: hunk count`, monacori.hunks === momenterm.hunks, `${monacori.hunks} != ${momenterm.hunks}`);
  note(`${name}: review signature`, monacori.signature === momenterm.signature, `${monacori.signature} != ${momenterm.signature}`);
  note(`${name}: branch`, (asObject(monacori.update).branch || "") === (asObject(momenterm.update).branch || ""));
  note(`${name}: update keys`, equalJSON(sorted(Object.keys(asObject(monacori.update))), sorted(Object.keys(asObject(momenterm.update)))));
  note(`${name}: file states`, equalJSON(fileStates(monacori), fileStates(momenterm)), `${JSON.stringify(fileStates(monacori))} != ${JSON.stringify(fileStates(momenterm))}`);
  note(`${name}: source metadata`, equalJSON(sourceMeta(monacori), sourceMeta(momenterm)), `${JSON.stringify(sourceMeta(monacori))} != ${JSON.stringify(sourceMeta(momenterm))}`);
  note(`${name}: lazy source paths`, equalJSON(sourceDataPaths(monacori), sourceDataPaths(momenterm)));
  note(`${name}: lazy source data`, equalJSON(lazySourceContract(monacori), lazySourceContract(momenterm)));
  note(`${name}: http environments`, equalJSON(asObject(monacori.update).httpEnvironments || {}, asObject(momenterm.update).httpEnvironments || {}));
  note(`${name}: lazy body count`, (monacori.lazyBodies || []).length === (momenterm.lazyBodies || []).length);
  note(`${name}: app shell markers`, equalJSON(markerContract(monacori.html), markerContract(momenterm.html)), `${JSON.stringify(markerContract(monacori.html))} != ${JSON.stringify(markerContract(momenterm.html))}`);
  note(`${name}: momenterm Darcula markers`, momenterm.html.includes("#2b2b2b") && momenterm.html.includes("#cc7832"));
}

try {
  if (!fs.existsSync(monacoriBuild)) {
    throw new Error(`Monacori build not found at ${monacoriBuild}. Run npm run build in ${monacoriRoot}.`);
  }
  compileDump();
  const { buildDiffReview } = await import(pathToFileURL(monacoriBuild));
  const scenarios = [
    ["modified", scenarioModified()],
    ["staged", scenarioStaged()],
    ["untracked text", scenarioUntrackedText()],
    ["untracked binary", scenarioUntrackedBinary()],
    ["source env", scenarioSourceAndEnv()],
    ["rename delete image", scenarioRenameDeleteImage()]
  ];
  for (const [name, repo] of scenarios) {
    const monacori = buildDiffReview({
      root: repo,
      includeUntracked: true,
      context: 80,
      staged: false,
      ignoreWhitespace: false,
      lazy: true,
      lazyLoad: true,
      app: true,
      watch: true,
      title: "A/B parity"
    });
    const momenterm = JSON.parse(run(dumpBin, [repo], { maxBuffer: 100 * 1024 * 1024 }));
    compareScenario(name, monacori, momenterm);
  }
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

if (failures.length) {
  console.error(`\n${failures.length} A/B parity checks failed`);
  process.exit(1);
}

console.log("\nA/B parity smoke ok");
