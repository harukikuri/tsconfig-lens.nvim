"use strict";
// Asks the project's own `typescript` about a file. Never resolves tsconfig
// semantics by itself: membership, extends and option values come from TypeScript.
//
// argv[2]: JSON { mode: "project" | "config", file, tsconfig? }
// stdout:  exactly one JSON value; errors are { error: { code, message } }.

const path = require("path");
const { execFileSync } = require("child_process");
const { pathToFileURL } = require("url");

function fail(code, message) {
  const err = new Error(message);
  err.code = code;
  throw err;
}

const slash = (p) => p.replace(/\\/g, "/");

function loadTypescript(file) {
  let pkg;
  try {
    pkg = require.resolve("typescript/package.json", { paths: [path.dirname(file)] });
  } catch {
    fail("no_typescript", "typescript is not installed in this project");
  }
  const json = require(pkg);
  // Aliased installs (e.g. "typescript": "npm:@typescript/typescript6") name the bin differently.
  const bins = typeof json.bin === "string" ? { tsc: json.bin } : json.bin || {};
  const tsc = bins.tsc || Object.entries(bins).find(([name]) => name.startsWith("tsc"))?.[1];
  if (!tsc) fail("no_typescript", `no tsc in ${pkg}`);
  const version = json.version;
  return { dir: path.dirname(pkg), tsc: path.join(path.dirname(pkg), tsc), version, major: Number(version.split(".")[0]) };
}

function showConfig(ts, tsconfig) {
  try {
    const out = execFileSync(process.execPath, [ts.tsc, "--showConfig", "-p", tsconfig], {
      cwd: path.dirname(tsconfig),
      encoding: "utf8",
      maxBuffer: 256 * 1024 * 1024,
    });
    return JSON.parse(out);
  } catch (e) {
    fail("tsconfig_error", String(e.stdout || e.message).trim());
  }
}

function candidates(file) {
  const fs = require("fs");
  const found = [];
  let dir = path.dirname(file);
  for (;;) {
    const c = path.join(dir, "tsconfig.json");
    if (fs.existsSync(c)) found.push(slash(c));
    const up = path.dirname(dir);
    if (up === dir) return found;
    dir = up;
  }
}

// ---------------------------------------------------------------- TypeScript <= 6

function parse(ts, cfg, scanFiles) {
  let fatal;
  const host = { ...ts.sys, onUnRecoverableConfigFileDiagnostic: (d) => (fatal = d) };
  if (!scanFiles) host.readDirectory = () => [];
  const pc = ts.getParsedCommandLineOfConfigFile(cfg, undefined, host);
  if (!pc) fail("tsconfig_error", fatal ? ts.flattenDiagnosticMessageText(fatal.messageText, "\n") : `cannot read ${cfg}`);
  return pc;
}

function findProjectLegacy(ts, file) {
  const seen = new Set();
  const check = (cfg) => {
    if (seen.has(cfg)) return null;
    seen.add(cfg);
    const pc = parse(ts, cfg, true);
    if (pc.fileNames.includes(file)) return cfg;
    for (const ref of pc.projectReferences || []) {
      const hit = check(slash(ts.resolveProjectReferencePath(ref)));
      if (hit) return hit;
    }
    return null;
  };
  for (const c of candidates(file)) {
    const hit = check(c);
    if (hit) return hit;
  }
  return null;
}

const extendedOf = (pc) => (pc.options.configFile && pc.options.configFile.extendedSourceFiles) || [];

// The tree is derived only from TypeScript's own `extendedSourceFiles` of each file:
// a direct child of X is a file in X's list that is not reachable through another file in it.
// If the lists do not fit together as a tree, only the flat list is returned.
function buildChain(ts, root, pc) {
  const all = extendedOf(pc);
  const ext = new Map([[root, all]]);
  for (const f of all) ext.set(f, extendedOf(parse(ts, f, false)));

  const children = (f) => {
    const list = ext.get(f);
    return list.filter((c) => !list.some((o) => o !== c && (ext.get(o) || []).includes(c)));
  };
  const consistent = [root, ...all].every((f) => {
    const reach = new Set();
    for (const c of children(f)) {
      reach.add(c);
      for (const x of ext.get(c) || []) reach.add(x);
    }
    const list = new Set(ext.get(f));
    return reach.size === list.size && [...reach].every((x) => list.has(x));
  });
  const files = [root, ...new Set(all)];
  if (!consistent) return { files, tree: null, order: null };

  const tree = (f) => ({ path: f, children: children(f).map(tree) });
  // TypeScript applies bases first (array: left to right), then the file itself.
  const order = (f) => [...children(f).flatMap(order), f];
  return { files, tree: tree(root), order: order(root) };
}

function keyLines(ts, file, text) {
  const lines = {};
  const json = ts.parseJsonText(file, text);
  const top = json.statements[0] && json.statements[0].expression;
  for (const prop of (top && top.properties) || []) {
    if (!prop.name || prop.name.text !== "compilerOptions" || !prop.initializer.properties) continue;
    for (const opt of prop.initializer.properties) {
      if (!opt.name) continue;
      lines[opt.name.text.toLowerCase()] = ts.getLineAndCharacterOfPosition(json, opt.name.getStart(json)).line + 1;
    }
  }
  return lines;
}

const CONFIG_DIR = "${configDir}";
function substituteConfigDir(value, dir) {
  if (typeof value === "string" && value.startsWith(CONFIG_DIR)) {
    return slash(path.resolve(dir, "." + value.slice(CONFIG_DIR.length)));
  }
  if (Array.isArray(value)) return value.map((v) => substituteConfigDir(v, dir));
  return value;
}

// Each file's own compilerOptions, converted by TypeScript into the same internal
// form as the final options, so the Lua side can verify its stacking against them.
function buildLayers(ts, root, pc, order) {
  const keys = new Set();
  const layers = order.map((f) => {
    const text = ts.sys.readFile(f) || "";
    const { config } = ts.readConfigFile(f, () => text);
    const rawOptions = (config && config.compilerOptions) || {};
    const rawByLower = {};
    for (const [k, v] of Object.entries(rawOptions)) rawByLower[k.toLowerCase()] = JSON.stringify(v);
    const conv = ts.convertCompilerOptionsFromJson(rawOptions, path.dirname(f), f);
    const options = {};
    const lineByLower = keyLines(ts, f, text);
    const lines = {};
    // `raw`: the value exactly as written in this file, for display only.
    const raw = {};
    for (const [k, v] of Object.entries(conv.options)) {
      if (k === "configFilePath" || k === "pathsBasePath") continue;
      options[k] = substituteConfigDir(v, path.dirname(root));
      if (lineByLower[k.toLowerCase()]) lines[k] = lineByLower[k.toLowerCase()];
      if (rawByLower[k.toLowerCase()] !== undefined) raw[k] = rawByLower[k.toLowerCase()];
      keys.add(k);
    }
    return { path: f, options, lines, raw };
  });
  const final = {};
  for (const k of keys) if (pc.options[k] !== undefined) final[k] = pc.options[k];
  return { layers, final };
}

function configLegacy(tsInfo, tsconfig) {
  const ts = require(tsInfo.dir);
  const show = showConfig(tsInfo, tsconfig);
  const pc = parse(ts, tsconfig, false);
  const root = slash(pc.options.configFile ? pc.options.configFile.fileName : tsconfig);
  const chain = buildChain(ts, root, pc);
  const out = { chain: { files: chain.files, tree: chain.tree }, show };
  if (chain.order) Object.assign(out, buildLayers(ts, root, pc, chain.order));
  return out;
}

// ---------------------------------------------------------------- TypeScript >= 7

async function findProjectNative(tsInfo, file) {
  const api_path = require.resolve("typescript/unstable/sync", { paths: [tsInfo.dir] });
  const { API } = await import(pathToFileURL(api_path).href);
  const api = new API({ cwd: path.dirname(file) });
  try {
    const seen = new Set();
    const check = (cfg) => {
      if (seen.has(cfg)) return null;
      seen.add(cfg);
      if (api.parseConfigFile(cfg).fileNames.includes(file)) return cfg;
      // The native API does not expose project references; `tsc --showConfig` does.
      for (const ref of showConfig(tsInfo, cfg).references || []) {
        let p = slash(path.resolve(path.dirname(cfg), ref.path));
        if (!p.endsWith(".json")) p += "/tsconfig.json";
        const hit = check(p);
        if (hit) return hit;
      }
      return null;
    };
    for (const c of candidates(file)) {
      const hit = check(c);
      if (hit) return hit;
    }
    return null;
  } finally {
    api.close();
  }
}

// ---------------------------------------------------------------- main

async function main() {
  const req = JSON.parse(process.argv[2]);
  const file = slash(path.resolve(req.file));
  const tsInfo = loadTypescript(file);
  const native = tsInfo.major >= 7;
  const base = { ts_version: tsInfo.version, native };

  if (req.mode === "project") {
    const project = native ? await findProjectNative(tsInfo, file) : findProjectLegacy(require(tsInfo.dir), file);
    return { ...base, project };
  }
  if (req.mode === "config") {
    const tsconfig = slash(path.resolve(req.tsconfig));
    const res = native ? { show: showConfig(tsInfo, tsconfig) } : configLegacy(tsInfo, tsconfig);
    const options = Object.entries(res.show.compilerOptions || {}).map(([k, v]) => [k, JSON.stringify(v)]);
    delete res.show;
    return { ...base, tsconfig, options, ...res };
  }
  fail("bad_request", `unknown mode: ${req.mode}`);
}

main()
  .catch((e) => ({ error: { code: e.code || "internal", message: String(e && e.message ? e.message : e) } }))
  .then((out) => process.stdout.write(JSON.stringify(out)));
