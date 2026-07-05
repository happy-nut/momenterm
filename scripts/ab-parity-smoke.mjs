#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const out = path.join(root, ".build/debug");
const dumpBin = path.join(out, "momenterm-native-model-dump");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "momenterm-native-model-"));
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
  run("git", ["config", "user.email", "native-model@example.com"], { cwd: dir });
  run("git", ["config", "user.name", "Native Model"], { cwd: dir });
  write(path.join(dir, "README.md"), "# fixture\n");
  write(path.join(dir, ".gitignore"), ".momenterm/\n");
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
  write(path.join(dir, ".momenterm/plan.md"), "# Plan\n\nNative source item.\n");
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
    path.join(root, "Sources/Momenterm/NativeSyntaxHighlighting.swift"),
    path.join(root, "Sources/Momenterm/NativeSourceCollector.swift"),
    path.join(root, "Sources/Momenterm/NativeHttpEnvironmentReader.swift"),
    path.join(root, "Sources/Momenterm/NativeReviewCore.swift"),
    path.join(root, "Sources/ABParityDump/main.swift"),
    "-framework", "Foundation"
  ]);
}

function dump(repo) {
  return JSON.parse(run(dumpBin, [repo]));
}

function paths(items) {
  return items.map((item) => item.displayPath || item.path).sort((a, b) => a.localeCompare(b));
}

function hasPath(items, wanted) {
  return paths(items).includes(wanted);
}

function validateCommon(name, review) {
  note(`${name}: native model root`, typeof review.root === "string" && review.root.length > 0);
  note(`${name}: native model branch`, typeof review.branch === "string" && review.branch.length > 0);
  note(`${name}: native model signature`, typeof review.signature === "string" && review.signature.length === 40);
  note(`${name}: diff count matches`, review.files === review.diffFiles.length);
  note(`${name}: hunk count matches`, review.hunks === review.diffFiles.reduce((sum, file) => sum + file.hunks.length, 0));
  note(`${name}: source files are native objects`, Array.isArray(review.sourceFiles) && review.sourceFiles.every((file) => typeof file.path === "string"));
  note(`${name}: file states are native objects`, Array.isArray(review.fileStates) && review.fileStates.every((item) => item.path && item.signature));
}

try {
  compileDump();
  const cases = {
    modified: dump(scenarioModified()),
    staged: dump(scenarioStaged()),
    "untracked text": dump(scenarioUntrackedText()),
    "untracked binary": dump(scenarioUntrackedBinary()),
    "source env": dump(scenarioSourceAndEnv()),
    "rename delete image": dump(scenarioRenameDeleteImage())
  };

  for (const [name, review] of Object.entries(cases)) {
    validateCommon(name, review);
  }

  note("modified: changed TypeScript diff", hasPath(cases.modified.diffFiles, "src/app.ts"));
  note("modified: source metadata marks changed file", cases.modified.sourceFiles.some((file) => file.path === "src/app.ts" && file.changed));
  note("staged: staged diff included", hasPath(cases.staged.diffFiles, "src/staged.js"));
  note("untracked text: native added file diff", hasPath(cases["untracked text"].diffFiles, "notes/new.md"));
  note("untracked text: source includes new file", hasPath(cases["untracked text"].sourceFiles, "notes/new.md"));
  note("untracked binary: large binary diff capped", cases["untracked binary"].diffFiles.some((file) => file.binary || JSON.stringify(file).includes("Binary files /dev/null")));
  note("source env: source includes plan", hasPath(cases["source env"].sourceFiles, ".momenterm/plan.md"));
  note("source env: HTTP environments parsed", JSON.stringify(cases["source env"].httpEnvironments).includes("example.test"));
  note("rename delete image: rename diff present", hasPath(cases["rename delete image"].diffFiles, "src/new-name.swift"));
  note("rename delete image: delete diff present", hasPath(cases["rename delete image"].diffFiles, "src/remove-me.txt"));

  if (failures.length) {
    console.error(`\n${failures.length} native model fixture checks failed`);
    process.exit(1);
  }
  console.log("\nnative model fixture smoke ok");
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
