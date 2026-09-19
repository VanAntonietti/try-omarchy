import { afterEach, expect, test } from "bun:test";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, symlinkSync, existsSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const roots: string[] = [];
const prepared = process.env.BLIP_TEST_SOURCE!;
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });

function fixture(config = "transport=omarchy-link\n") {
  const home = mkdtempSync(join(tmpdir(), "blip-transport-"));
  roots.push(home);
  mkdirSync(join(home, ".config/blip"), { recursive: true });
  mkdirSync(join(home, "bin"));
  writeFileSync(join(home, ".config/blip/bridge.conf"), config);
  for (const tool of ["imsg", "imsg-send", "imsg-read", "contacts", "contact-save"]) {
    copyFileSync(join(prepared, "bridge/linux/blip-shim"), join(home, "bin", tool));
    chmodSync(join(home, "bin", tool), 0o755);
  }
  try { copyFileSync(join(prepared, "bridge/linux/blip-link.ts"), join(home, "bin/blip-link.ts")); } catch { /* red before implementation */ }
  writeFileSync(join(home, "bin/omarchy-link"), `#!/usr/bin/env bun
const capabilities = ["messages.conversations.list", "messages.thread.list", "messages.unread.get", "messages.send.propose"];
if (process.argv[2] === "status") {
  let change = {};
  if (process.env.WATCH_FIXTURE) {
    const {readFileSync,writeFileSync} = await import("node:fs");
    let count = 0;
    try { count = Number(readFileSync(process.env.HOME + "/poll-count", "utf8")); } catch {}
    writeFileSync(process.env.HOME + "/poll-count", String(count + 1));
    change = {messagesRevision:count > 0 ? 1 : 0,contentAllowed:count < 3,privateField:"must not escape"};
  }
  if (process.env.LOCK_AFTER_QUERY) {
    const { existsSync } = await import("node:fs");
    change = {contentAllowed:!existsSync(process.env.HOME + "/query-completed")};
  }
  console.log(JSON.stringify({available:true,hostAvailable:true,contentAllowed:true,blipAdapterVersion:1,capabilities,messagesRevision:0,...change,...JSON.parse(process.env.STATUS_OVERRIDE || "{}")}));
} else if (process.argv[2] === "call") {
  const request = JSON.parse(await Bun.stdin.text());
  if (JSON.stringify(request) !== process.env.EXPECT_REQUEST) process.exit(65);
  if (process.env.CALL_ERROR) { console.error("Invented private error"); console.log(JSON.stringify({error:{code:"service.unavailable"}})); process.exit(0); }
  if (process.env.LOCK_AFTER_QUERY) {
    const { writeFileSync } = await import("node:fs");
    writeFileSync(process.env.HOME + "/query-completed", "done");
  }
  const rows = [{chat:"opaque-dm",text:"Invented text",from_me:false,ts:"2026-09-14T10:00:00Z"}];
  console.log(JSON.stringify({ rows: process.env.EXCESS_ROWS ? Array(151).fill(rows[0]) : rows }));
} else if (process.argv[2] === "create-message") {
  const request = JSON.parse(await Bun.stdin.text());
  if (JSON.stringify(request) !== process.env.EXPECT_REQUEST || process.argv.length !== 3) process.exit(65);
  const { appendFileSync } = await import("node:fs");
  appendFileSync(process.env.HOME + "/attempts", "attempt\\n");
  console.log(JSON.stringify({outcome:process.env.SEND_OUTCOME || "accepted"}));
} else { process.exit(65); }
`);
  chmodSync(join(home, "bin/omarchy-link"), 0o755);
  const env: NodeJS.ProcessEnv = { ...process.env, HOME: home, BLIP_BRIDGE_CONF: join(home, ".config/blip/bridge.conf"), PATH: `${home}/bin:${process.env.PATH}` };
  return { home, env, run: (tool: string, args: readonly string[], input: string | Buffer = "") => spawnSync(join(home, "bin", tool), args, { env, input, encoding: "utf8", timeout: 5000 }) };
}

test("explicit Link selection refuses unsupported host commands without SSH fallback", () => {
  const f = fixture();
  const result = f.run("imsg", ["arbitrary-shell-command"]);
  expect(result.status).toBe(69);
  expect(result.stderr).toBe("blip: operation unavailable through Omarchy Link\n");
});

test.each([
  ["--json", "chats", "300"],
  ["--json", "groups"],
  ["--json", "--rich", "thread", "--chat", "opaque-group", "40"],
  ["--json", "thread", "--chat", "opaque-dm", "400"],
].map(args => ({ args })))("shared conversation and thread behavior reaches typed Link queries: %j", ({ args }) => {
  const f = fixture();
  const request = args.includes("thread")
    ? { method: "messages.thread.list", conversationId: args.at(-2), limit: Number(args.at(-1)) }
    : { method: "messages.conversations.list", view: args[1], limit: args[1] === "groups" ? 300 : Number(args[2]) };
  f.env.EXPECT_REQUEST = JSON.stringify(request);
  expect(f.run("imsg", args).status).toBe(0);
});

test.each([{}, { transport: "ssh" }])("SSH remains the default with its non-consuming probe: %j", selection => {
  const f = fixture(`host=you@your-mac\n${selection.transport ? "transport=ssh\n" : ""}`);
  writeFileSync(join(f.home, "bin/ssh"), `#!/usr/bin/env python3
import json, sys
if "-n" in sys.argv: sys.exit(0)
print(json.dumps({"args":sys.argv[1:],"input":sys.stdin.read()}))
`, { mode: 0o755 });
  const result = f.run("imsg-send", ["--to", "+15551234567", "--text-stdin"], "Invented body");
  expect(result.status).toBe(0);
  const response = JSON.parse(result.stdout);
  expect(response.input).toBe("Invented body");
  expect(response.args).toEqual(["--", "you@your-mac", "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH python3 $HOME/.blip/bin/imsg-send '--to' '+15551234567' '--text-stdin'"]);
});

test.each([
  { available: false }, { hostAvailable: false }, { contentAllowed: false },
  { blipAdapterVersion: 0 }, { capabilities: [] },
])("unavailable, locked, old and unprovisioned sessions cannot query or send: %j", override => {
  const f = fixture();
  f.env.STATUS_OVERRIDE = JSON.stringify(override);
  expect(f.run("imsg", ["--json", "recent", "150"]).status).toBe(69);
  expect(f.run("imsg-send", ["--to", "opaque-dm", "--text-stdin"], "Invented body").status).toBe(69);
  expect(() => readFileSync(join(f.home, "attempts"))).toThrow();
});

test.each(["failed", "uncertain", "rejected", "unexpected"])("a %s send outcome is never replayed or reported delivered", outcome => {
  const f = fixture();
  f.env.EXPECT_REQUEST = JSON.stringify({ conversationId: "opaque-dm", text: "Invented body" });
  f.env.SEND_OUTCOME = outcome;
  const result = f.run("imsg-send", ["--to", "opaque-dm", "--text-stdin"], "Invented body");
  expect(result.status).toBe(69);
  expect(result.stdout).toBe("");
  expect(result.stderr).not.toContain("Invented body");
  expect(readFileSync(join(f.home, "attempts"), "utf8")).toBe("attempt\n");
});

test.each([
  { tool: "imsg", args: ["--json", "recent", "8193"] },
  { tool: "imsg", args: ["--json", "recent", "0"] },
  { tool: "imsg", args: ["--json", "thread", "--chat", "group", "40", "--shell"] },
  { tool: "imsg", args: ["attachment", "1"] },
  { tool: "imsg-read", args: ["--all"] },
  { tool: "contacts", args: ["dump"] },
  { tool: "contact-save", args: [] },
  { tool: "imsg-send", args: ["--to", "group", "--text", "Invented body"] },
  { tool: "imsg-send", args: ["--to", "group", "--file-stdin", "--text-stdin"] },
])("unsupported operations fail closed without echoing arguments: %j", ({tool, args}) => {
  const f = fixture();
  const result = f.run(tool, args, "Invented body");
  expect(result.status).toBe(69);
  expect(result.stderr).toBe("blip: operation unavailable through Omarchy Link\n");
  expect(result.stdout).toBe("");
});

test.each(["LOCK_AFTER_QUERY", "EXCESS_ROWS"])("late or oversized content is withheld: %s", flag => {
  const f = fixture();
  f.env[flag] = "1";
  f.env.EXPECT_REQUEST = JSON.stringify({ method: "messages.conversations.list", view: "recent", limit: 150 });
  const result = f.run("imsg", ["--json", "recent", "150"]);
  expect(result.status).toBe(69);
  expect(result.stdout).toBe("");
});

test("host errors never escape into diagnostics or look like empty success", () => {
  const f = fixture();
  f.env.EXPECT_REQUEST = JSON.stringify({ method: "messages.conversations.list", view: "recent", limit: 150 });
  f.env.CALL_ERROR = "1";
  const result = f.run("imsg", ["--json", "recent", "150"]);
  expect(result.status).toBe(69);
  expect(result.stdout).toBe("");
  expect(result.stderr).not.toContain("Invented private error");
});

test("content-free Messages Invalidations drive the existing watch refresh and stop on lock", () => {
  const f = fixture();
  f.env.WATCH_FIXTURE = "1";
  const result = f.run("imsg", ["watch"]);
  expect(result.status).toBe(69);
  expect(result.stdout).toBe("ready\nchanged\n");
});

test("setup refuses a dangling shim symlink instead of writing through it", () => {
  const f = fixture();
  rmSync(join(f.home, "bin/imsg"));
  symlinkSync(join(f.home, "unrelated"), join(f.home, "bin/imsg"));
  const result = spawnSync(join(prepared, "scripts/blip-setup"), ["--transport=omarchy-link"], { env: f.env, encoding: "utf8", timeout: 5000 });
  expect(result.status).toBe(69);
  expect(existsSync(join(f.home, "unrelated"))).toBe(false);
});

test("Read mode cannot submit a write even when the adapter is packaged", () => {
  const f = fixture();
  f.env.STATUS_OVERRIDE = JSON.stringify({capabilities:["messages.conversations.list", "messages.thread.list", "messages.unread.get"]});
  expect(f.run("imsg-send", ["--to", "opaque-dm", "--text-stdin"], "Invented body").status).toBe(69);
  expect(existsSync(join(f.home, "attempts"))).toBe(false);
});

test("explicit Link setup checks packaged capability before bypassing SSH and preserves preferences", () => {
  const f = fixture("automation=off\nui_font_size=14\n");
  const command = join(prepared, "scripts/blip-setup");
  f.env.STATUS_OVERRIDE = JSON.stringify({ blipAdapterVersion: 0 });
  expect(spawnSync(command, ["--transport=omarchy-link"], { env: f.env, encoding: "utf8", timeout: 5000 }).status).toBe(69);
  expect(readFileSync(join(f.home, ".config/blip/bridge.conf"), "utf8")).toBe("automation=off\nui_font_size=14\n");
  f.env.STATUS_OVERRIDE = "{}";
  const result = spawnSync(command, ["--transport=omarchy-link"], { env: f.env, encoding: "utf8", timeout: 5000 });
  expect(result.status).toBe(0);
  expect(readFileSync(join(f.home, ".config/blip/bridge.conf"), "utf8")).toContain("transport=omarchy-link\n");
  expect(readFileSync(join(f.home, ".config/blip/bridge.conf"), "utf8")).toContain("ui_font_size=14\n");
  expect(statSync(join(f.home, ".config/blip/bridge.conf")).mode & 0o777).toBe(0o600);
  expect(() => readFileSync(join(f.home, ".ssh/config"))).toThrow();
});

test.each([
  { name: "empty", input: Buffer.alloc(0) },
  { name: "oversized", input: Buffer.alloc(16385, 65) },
  { name: "invalid UTF-8", input: Buffer.from([0xc3, 0x28]) },
])("invalid message streams are refused before review: $name", ({ input }) => {
  const f = fixture();
  const result = f.run("imsg-send", ["--to", "opaque-dm", "--text-stdin"], input);
  expect(result.status).toBe(69);
  expect(result.stdout).toBe("");
  expect(existsSync(join(f.home, "attempts"))).toBe(false);
});

test("a leading Unicode BOM in message text is preserved, not treated as a file signature", () => {
  const f = fixture();
  const text = "\uFEFFInvented message";
  f.env.EXPECT_REQUEST = JSON.stringify({ conversationId: "opaque-dm", text });
  expect(f.run("imsg-send", ["--to", "opaque-dm", "--text-stdin"], text).status).toBe(0);
});

test("a send carries exact text on stdin and --yes does not bypass canonical review", () => {
  const f = fixture();
  const text = "Invented 'message'\n--yes $(not-a-command)";
  f.env.EXPECT_REQUEST = JSON.stringify({ conversationId: "opaque-group", text });
  const result = f.run("imsg-send", ["--chat-id", "opaque-group", "--yes", "--text-stdin", "--keep-dashes"], text);
  expect(result.status).toBe(0);
  expect(result.stdout).toBe("accepted\n");
  expect(result.stderr).toBe("");
  expect(readFileSync(join(f.home, "attempts"), "utf8")).toBe("attempt\n");
});

test("recent conversation queries use the local CLI's bounded JSON stdin contract", () => {
  const f = fixture();
  f.env.EXPECT_REQUEST = JSON.stringify({ method: "messages.conversations.list", view: "recent", limit: 150 });
  const result = f.run("imsg", ["--json", "recent", "150"]);
  expect(result.status).toBe(0);
  expect(JSON.parse(result.stdout)).toEqual([{ chat: "opaque-dm", text: "Invented text", from_me: false, ts: "2026-09-14T10:00:00Z" }]);
  expect(result.stderr).toBe("");
});
