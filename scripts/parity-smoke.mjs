#!/usr/bin/env node
import fs from "node:fs";
import vm from "node:vm";

const root = new URL("..", import.meta.url);
const corePath = new URL("Sources/Momenterm/NativeReviewCore.swift", root);
const core = fs.readFileSync(corePath, "utf8");
const scriptMatch = core.match(/private static let clientScript = """\n([\s\S]*?)\n    """\n\n    private static func escape/);
if (!scriptMatch) {
  console.error("not ok - embedded client script was not found");
  process.exit(1);
}

function decodeSwiftMultilineString(value) {
  return value.replace(/\\\\/g, "\\");
}

const clientScript = decodeSwiftMultilineString(scriptMatch[1]);
const failures = [];

function check(name, ok, detail = "") {
  if (ok) {
    console.log(`ok - ${name}`);
  } else {
    console.error(`not ok - ${name}${detail ? `: ${detail}` : ""}`);
    failures.push(name);
  }
}

function has(pattern) {
  return typeof pattern === "string" ? core.includes(pattern) || clientScript.includes(pattern) : pattern.test(core) || pattern.test(clientScript);
}

class FakeClassList {
  add() {}
  remove() {}
  toggle() { return false; }
  contains() { return false; }
}

class FakeElement {
  constructor(id = "") {
    this.id = id;
    this.dataset = {};
    this.style = {};
    this.classList = new FakeClassList();
    this.children = [];
    this.attributes = [];
    this.value = "";
    this.textContent = "";
    this.innerHTML = "";
    this.scrollTop = 0;
    this.scrollHeight = 0;
  }
  addEventListener() {}
  setAttribute(name, value) { this[name] = String(value); }
  getAttribute(name) { return this[name] || ""; }
  removeAttribute(name) { delete this[name]; }
  appendChild(child) { this.children.push(child); return child; }
  querySelector() { return new FakeElement(); }
  querySelectorAll() { return []; }
  closest() { return null; }
  focus() {}
  scrollIntoView() {}
  getBoundingClientRect() { return { top: 80 }; }
  remove() {}
}

const elementCache = new Map();
function fakeElement(selector) {
  if (!elementCache.has(selector)) elementCache.set(selector, new FakeElement(selector));
  return elementCache.get(selector);
}

const localStore = new Map();
const sandbox = {
  console,
  setTimeout,
  clearTimeout,
  Promise,
  CSS: { escape: (value) => String(value).replace(/"/g, '\\"') },
  localStorage: {
    getItem: (key) => localStore.has(key) ? localStore.get(key) : null,
    setItem: (key, value) => localStore.set(key, String(value))
  },
  document: {
    documentElement: new FakeElement("html"),
    body: new FakeElement("body"),
    querySelector: (selector) => fakeElement(selector),
    querySelectorAll: () => [],
    createElement: (tag) => new FakeElement(tag),
    createRange: () => ({ selectNodeContents() {} }),
    addEventListener() {}
  },
  window: {
    __momentermData: { root: "/tmp/momenterm-parity", sourceFiles: [] },
    momentermSettings: { all: {}, set() {} },
    momentermPty: { spawn: () => Promise.resolve({ ok: true, id: 1 }), write() {}, onData() {}, onExit() {} },
    momentermGit: { log: () => Promise.resolve([]), commitDiff: () => Promise.resolve({}) },
    momentermHttp: { send: () => Promise.resolve({ ok: true }) },
    momentermClipboard: { write() {} },
    momentermApp: { revealInFinder() {}, openTerminalAt() {} },
    getSelection: () => ({ removeAllRanges() {}, addRange() {} })
  }
};
sandbox.window.window = sandbox.window;
sandbox.window.document = sandbox.document;
sandbox.window.localStorage = sandbox.localStorage;
sandbox.window.CSS = sandbox.CSS;
sandbox.window.setTimeout = setTimeout;
sandbox.window.clearTimeout = clearTimeout;

try {
  vm.runInNewContext(clientScript, sandbox, { filename: "momenterm-client.js" });
  check("embedded client script boots in VM", true);
} catch (error) {
  check("embedded client script boots in VM", false, error.stack || String(error));
}

const highlighter = sandbox.window.__momentermHighlightCode;
if (typeof highlighter === "function") {
  const html = highlighter("@MainActor function makeThing(value) { let model: Widget = 42; return model }", "src/app.ts");
  check("syntax: decorators highlighted", html.includes("tok-decorator"));
  check("syntax: keywords highlighted", html.includes("tok-keyword"));
  check("syntax: function calls highlighted", html.includes("tok-fn"));
  check("syntax: PascalCase types highlighted", html.includes("tok-type"));
  check("syntax: numbers highlighted", html.includes("tok-number"));
} else {
  check("syntax: highlighter exported for smoke", false);
}

const shortcutChecks = [
  ["shortcut: F7 next change", /e\.key === 'F7'.*navigateDiff\(e\.shiftKey \? -1 : 1\)/s],
  ["shortcut: Shift+F7 previous change", /e\.key === 'F7'.*e\.shiftKey \? -1 : 1/s],
  ["shortcut: Cmd+0 focuses changes", /e\.key === '0'.*#changes-panel \.file-link/s],
  ["shortcut: Cmd+1 opens source", /e\.key === '1'.*openSource\(current\.path \|\| firstChangedPath\(\)\)/s],
  ["shortcut: Cmd+9 opens history", /e\.key === '9'.*loadHistory\(\)/s],
  ["shortcut: Cmd+Down opens source at caret", /e\.key === 'ArrowDown'.*openSource\(current\.path \|\| firstChangedPath\(\), current\.line\)/s],
  ["shortcut: Cmd+A scopes selection", /key\.toLowerCase\(\) === 'a'.*selectNodeContents\(target\)/s],
  ["shortcut: double Shift opens quick open", /e\.key === 'Shift'.*openQuickOpen\(\)/s],
  ["shortcut: quick-open ArrowDown", /#quick-open-input[\s\S]*e\.key === 'ArrowDown'[\s\S]*quickMove\(1\)/],
  ["shortcut: quick-open ArrowUp", /#quick-open-input[\s\S]*e\.key === 'ArrowUp'[\s\S]*quickMove\(-1\)/],
  ["shortcut: quick-open Enter", /#quick-open-input[\s\S]*e\.key === 'Enter'[\s\S]*openSource\(active\.dataset\.path\)/],
  ["shortcut: q opens question composer", /e\.key === 'q'.*openComposer\('q'\)/s],
  ["shortcut: c opens change composer", /e\.key === 'c'.*openComposer\('c'\)/s],
  ["shortcut: Cmd+Enter saves composer", /e\.metaKey \|\| e\.ctrlKey.*e\.key === 'Enter'.*save\(\)/s],
  ["shortcut: ArrowDown selects comment", /e\.key === 'ArrowDown'.*selectAdjacentComment/s],
  ["shortcut: ArrowUp selects comment", /e\.key === 'ArrowUp'.*selectAdjacentComment/s],
  ["shortcut: e edits selected comment", /e\.key === 'e'.*editSelectedComment\(\)/s],
  ["shortcut: Backspace deletes selected comment", /e\.key === 'Backspace'.*deleteSelectedComment\(\)/s],
  ["shortcut: Escape clears selected comment", /e\.key === 'Escape'.*selectComment\(null\)/s],
  ["shortcut: viewed toggle", /e\.key === 'v'.*toggleViewed\(current\.path\)/s],
  ["shortcut: PageUp and PageDown scroll diff", /PageDown.*PageUp.*scrollTop/s],
  ["shortcut: merged Opt+Enter menu", /e\.altKey && e\.key === 'Enter'.*openMergedMenu/s],
  ["shortcut: merged Opt+Arrow headers", /e\.altKey && \(e\.key === 'ArrowDown' \|\| e\.key === 'ArrowUp'\).*stepMergedHeader/s],
  ["shortcut: dock maximize Cmd+Shift+quote", /e\.shiftKey && e\.key === "'"/],
  ["shortcut: sidebar ArrowDown", /function sidebarKeydown[\s\S]*e\.key === 'ArrowDown'/],
  ["shortcut: sidebar ArrowUp", /function sidebarKeydown[\s\S]*e\.key === 'ArrowUp'/],
  ["shortcut: sidebar Enter opens row", /function sidebarKeydown[\s\S]*e\.key === 'Enter'[\s\S]*e\.currentTarget\.click\(\)/],
  ["shortcut: sidebar Opt+Enter opens action menu", /e\.altKey && e\.key === 'Enter'[\s\S]*openFileActionMenu/],
  ["shortcut: history ArrowDown", /current\.view === 'history' && e\.key === 'ArrowDown'.*historyMove\(1\)/s],
  ["shortcut: history ArrowUp", /current\.view === 'history' && e\.key === 'ArrowUp'.*historyMove\(-1\)/s],
  ["shortcut: history Enter opens commit", /current\.view === 'history' && e\.key === 'Enter'.*openHistoryCommit/s],
  ["shortcut: terminal Enter", /#terminal-panes[\s\S]*e\.key === 'Enter'[\s\S]*writeActive\('\\\\r'\)/],
  ["shortcut: terminal Backspace", /#terminal-panes[\s\S]*e\.key === 'Backspace'[\s\S]*String\.fromCharCode\(127\)/],
  ["shortcut: terminal Tab", /#terminal-panes[\s\S]*e\.key === 'Tab'[\s\S]*writeActive\('\\\\t'\)/],
  ["shortcut: terminal Ctrl+C", /e\.ctrlKey && e\.key\.toLowerCase\(\) === 'c'[\s\S]*String\.fromCharCode\(3\)/]
];
for (const [name, pattern] of shortcutChecks) check(name, has(pattern));

const settingsChecks = [
  ["settings: Darcula default", /theme:\s*'darcula'/],
  ["settings: Darcula theme option", /data-theme-option=\\?"darcula\\?"/],
  ["settings: theme selector", "settings-theme"],
  ["settings: language selector", "settings-language"],
  ["settings: plan prompt template", "settings-prompt-plan"],
  ["settings: question prompt template", "settings-prompt-q"],
  ["settings: change prompt template", "settings-prompt-c"],
  ["settings: reset action", "settings-reset"],
  ["settings: saved state", "settings-saved"],
  ["settings: local persistence", "momenterm-setting-"],
  ["settings: native bridge persistence", /momentermSettings\)\s*window\.momentermSettings\.set/],
  ["settings: theme restored on boot", /applyTheme\(getSetting\('theme'\)\)/],
  ["settings: prompt templates feed merged handoff", /getSetting\('promptC'\).*getSetting\('promptQ'\).*getSetting\('promptPlan'\)/s]
];
for (const [name, pattern] of settingsChecks) check(name, has(pattern));

const darculaChecks = [
  ["darcula: editor background", "--bg:#2b2b2b"],
  ["darcula: tool window panel", "--panel:#3c3f41"],
  ["darcula: foreground", "--text:#a9b7c6"],
  ["darcula: keyword orange", "--kw:#cc7832"],
  ["darcula: string green", "--str:#6a8759"],
  ["darcula: function yellow", "--fn:#ffc66d"],
  ["darcula: type foreground", "--type:#a9b7c6"],
  ["darcula: decorator olive", "--decor:#bbb529"],
  ["darcula: topbar compact", ".topbar{position:fixed;left:0;right:0;top:0;height:44px"],
  ["darcula: compact activity rail", ".activity{position:fixed;top:44px;bottom:0;left:0;width:54px"],
  ["darcula: activity active state", ".activity button.active"],
  ["darcula: source editor background", ".source-body{padding:10px 12px"],
  ["darcula: diff editor background", ".diff2html-container{padding:10px 12px"],
  ["darcula: sidebar tab wiring", "function setSidebarTab"]
];
for (const [name, pattern] of darculaChecks) check(name, has(pattern));

const featureChecks = [
  ["feature: clean tree opens source", /!changedPaths\(\)\.length && sourceFiles\(\)\[0\].*openSource/s],
  ["feature: markdown HTML is sanitized", "sanitizeInlineHtml"],
  ["feature: CSV render path", "parseCsvLine"],
  ["feature: diff update defers while composing", /if \(composing\) \{ pendingUpdate = update; return; \}/],
  ["feature: comment remap keeps comments", "function remapComments"],
  ["feature: terminal split", "function splitTerminal"],
  ["feature: terminal pane focus", "function focusTerminalPane"],
  ["feature: terminal pane rename", "function renameTerminalPane"],
  ["feature: history graph", "computeHistoryGraph"],
  ["feature: HTTP dock", "http-client"]
];
for (const [name, pattern] of featureChecks) check(name, has(pattern));

const forbiddenRuntime = [
  "monacori" + "/dist",
  "monacori" + "-bridge",
  "MONACORI" + "_DIST",
  "NODE" + "_BIN",
  "buildDiff" + "Review(",
  "renderWelcome" + "Html(",
  "performHttp" + "Request("
];
for (const marker of forbiddenRuntime) check(`runtime dependency absent: ${marker}`, !core.includes(marker));

if (failures.length) {
  console.error(`\n${failures.length} parity smoke checks failed`);
  process.exit(1);
}
console.log("\nparity smoke ok");
