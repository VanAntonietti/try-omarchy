// Temporary Try Omarchy adapter, below Blip's existing UI/state models.
// No shell commands, message logs, automatic replay, or SSH fallback.
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, readSync, renameSync, writeFileSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

type ObjectValue = Record<string, unknown>;
const READ_CAPABILITIES = ["messages.conversations.list", "messages.thread.list", "messages.unread.get"];

function object(value: unknown): ObjectValue {
  if (!value || typeof value !== "object" || Array.isArray(value)) unavailable();
  return value as ObjectValue;
}

function cli(command: string, request?: ObjectValue): ObjectValue {
  const result = spawnSync("omarchy-link", [command], {
    input: request === undefined ? "" : JSON.stringify(request),
    encoding: "utf8", timeout: command === "create-message" ? 120000 : 2000, maxBuffer: 65536,
    // Diagnostics from a future host adapter must not become Blip logs.
    stdio: ["pipe", "pipe", "ignore"],
  });
  if (result.error || result.status !== 0) unavailable();
  try { return object(JSON.parse(result.stdout)); } catch { return unavailable(); }
}

function status(): ObjectValue {
  const value = cli("status");
  const capabilities = value.capabilities;
  if (value.available !== true || value.hostAvailable !== true || value.contentAllowed !== true
      || value.blipAdapterVersion !== 1 || !Array.isArray(capabilities)
      || !READ_CAPABILITIES.every(c => capabilities.includes(c))) unavailable();
  return value;
}

function limit(value: string | undefined): number {
  if (!value || !/^[1-9][0-9]*$/.test(value) || Number(value) > 8192) unavailable();
  return Number(value);
}

function unavailable(): never {
  process.stderr.write("blip: operation unavailable through Omarchy Link\n");
  process.exit(69);
}

function send(options: string[]): void {
  const request: ObjectValue = {};
  const flags = new Set<string>();
  for (let index = 0; index < options.length; index++) {
    const flag = options[index];
    if (flags.has(flag)) unavailable();
    flags.add(flag);
    if (flag === "--to" || flag === "--chat-id") {
      if (request.conversationId !== undefined) unavailable();
      const id = options[++index];
      if (!id || id.length > 512 || /[\x00-\x1f\x7f]/.test(id)) unavailable();
      // Even --to is an existing-conversation lookup, never new-recipient compose.
      request.conversationId = id;
    } else if (flag === "--service") {
      const service = options[++index];
      if (!["SMS", "RCS", "iMessage"].includes(service)) unavailable();
      request.expectedService = service;
    } else if (!["--yes", "--text-stdin", "--keep-dashes"].includes(flag)) unavailable();
  }
  if (!request.conversationId || !flags.has("--text-stdin")) unavailable();
  const state = status();
  if (!(state.capabilities as string[]).includes("messages.send.propose")) unavailable();
  const bytes = Buffer.alloc(16385);
  let length = 0;
  while (length < bytes.length) {
    const count = readSync(0, bytes, length, bytes.length - length, null);
    if (!count) break;
    length += count;
  }
  if (length === 0 || length > 16384) unavailable();
  try { request.text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes.subarray(0, length)); }
  catch { unavailable(); }
  // This CLI command must own a visible review; --yes is deliberately NOT forwarded.
  // One attempt only. A disconnect or unknown outcome can never cause replay.
  const result = cli("create-message", request);
  if (result.outcome !== "accepted") unavailable();
  process.stdout.write("accepted\n");
}

async function watch(): Promise<never> {
  let previous: number | undefined;
  let heartbeat = Date.now();
  for (;;) {
    const revision = status().messagesRevision;
    if (typeof revision !== "number" || !Number.isSafeInteger(revision) || revision < 0) unavailable();
    if (previous === undefined) process.stdout.write("ready\n");
    else if (revision !== previous) process.stdout.write("changed\n");
    else if (Date.now() - heartbeat >= 30000) {
      process.stdout.write("hb\n");
      heartbeat = Date.now();
    }
    previous = revision;
    await Bun.sleep(250);
  }
}

async function setup(source: string): Promise<void> {
  status(); // No files, SSH probes, keys, or permission prompts before this gate.
  const home = process.env.HOME;
  if (!home || !source) unavailable();
  const directory = join(home, ".config/blip");
  const path = join(directory, "bridge.conf");
  const configStat = lstatSync(path, { throwIfNoEntry: false });
  if (configStat && !configStat.isFile()) unavailable();
  const previous = existsSync(path) ? readFileSync(path, "utf8") : "";
  // Share upstream's bin_dir rules rather than introducing a second path policy.
  const { parseBinDir } = await import(pathToFileURL(join(source, "bin-dir.ts")).href);
  const bin = parseBinDir(process.env.BLIP_BIN_DIR ? `bin_dir=${process.env.BLIP_BIN_DIR}` : previous, home);
  const tools = ["imsg", "imsg-send", "imsg-read", "contacts", "contact-save"];
  // Refuse unrelated executables rather than silently replacing user tools.
  for (const name of [...tools, "blip-link.ts"]) {
    const target = join(bin, name);
    const info = lstatSync(target, { throwIfNoEntry: false });
    if (info && (!info.isFile()
        || !readFileSync(target, "utf8").includes(name === "blip-link.ts" ? "Temporary Try Omarchy adapter" : "blip-shim"))) unavailable();
  }
  mkdirSync(bin, { recursive: true });
  for (const tool of tools) {
    copyFileSync(join(source, "bridge/linux/blip-shim"), join(bin, tool));
    chmodSync(join(bin, tool), 0o755);
  }
  copyFileSync(join(source, "bridge/linux/blip-link.ts"), join(bin, "blip-link.ts"));
  chmodSync(join(bin, "blip-link.ts"), 0o644);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const kept = previous.split("\n").filter(line => !/^\s*(transport|bin_dir|push_read)\s*=/.test(line));
  const configuration = kept.join("\n") + `\ntransport=omarchy-link\nbin_dir=${bin}\npush_read=off\n`;
  const temporary = path + `.tmp.${process.pid}`;
  writeFileSync(temporary, configuration, { mode: 0o600, flag: "wx" });
  renameSync(temporary, path);
  process.stdout.write("blip: Omarchy Link selected; SSH setup skipped\n");
}

async function main(args: string[]): Promise<void> {
  const [tool, ...options] = args;
  if (tool === "setup" && options.length === 1) return setup(options[0]);
  if (tool === "imsg-send") return send(options);
  if (tool === "imsg" && options.length === 1 && options[0] === "watch") return watch();
  if (tool !== "imsg" || options.shift() !== "--json") unavailable();
  if (options[0] === "--rich") options.shift();
  let request: ObjectValue;
  if ((options[0] === "recent" || options[0] === "chats") && options.length === 2) {
    request = { method: "messages.conversations.list", view: options[0], limit: limit(options[1]) };
  } else if (options[0] === "groups" && options.length === 1) {
    request = { method: "messages.conversations.list", view: "groups", limit: 300 };
  } else if (options[0] === "thread" && options[1] === "--chat" && options.length === 4
      && options[2].length > 0 && options[2].length <= 512 && !/[\x00-\x1f\x7f]/.test(options[2])) {
    request = { method: "messages.thread.list", conversationId: options[2], limit: limit(options[3]) };
  } else unavailable();
  status();
  const result = cli("call", request);
  if (result.error || !Array.isArray(result.rows) || result.rows.length > Number(request.limit)) unavailable();
  status(); // A late response must not expose content after a lock or disconnect.
  process.stdout.write(JSON.stringify(result.rows) + "\n");
}

if (import.meta.main) main(process.argv.slice(2)).catch(() => unavailable());
