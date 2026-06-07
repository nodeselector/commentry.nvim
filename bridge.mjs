#!/usr/bin/env node
// bridge.mjs — WebSocket ↔ stdio bridge for commentry.nvim copilot_app adapter
// Reads ws.port and ws.token from ~/.copilot/run/, connects to the
// GitHub Copilot App backend, and forwards JSON lines between stdin and WS.
// Works with Node 22+ (native WebSocket) or Bun.

import { readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { createInterface } from "readline";

const RUN_DIR = join(homedir(), ".copilot", "run");

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function readRunFile(name) {
  try {
    return readFileSync(join(RUN_DIR, name), "utf8").trim();
  } catch (err) {
    emit({ type: "__error", message: `cannot read ${name}: ${err.message}` });
    process.exit(1);
  }
}

const port = readRunFile("ws.port");
const token = readRunFile("ws.token");
const url = `ws://127.0.0.1:${port}?token=${token}`;

process.stderr.write(`[bridge] connecting to ws://127.0.0.1:${port}?token=***\n`);

const pendingQueue = [];
const ws = new WebSocket(url);

ws.addEventListener("open", () => {
  process.stderr.write("[bridge] connected\n");
  emit({ type: "__connected" });
  for (const msg of pendingQueue) {
    ws.send(msg);
  }
  pendingQueue.length = 0;
});

ws.addEventListener("message", (event) => {
  const data = typeof event.data === "string" ? event.data : event.data.toString();
  process.stdout.write(data + "\n");
});

ws.addEventListener("error", (event) => {
  const msg = event.message || "unknown";
  process.stderr.write(`[bridge] ws error: ${msg}\n`);
  emit({ type: "__error", message: `ws error: ${msg}` });
});

ws.addEventListener("close", (event) => {
  process.stderr.write(`[bridge] disconnected (code=${event.code})\n`);
  process.exit(0);
});

const rl = createInterface({ input: process.stdin, terminal: false });
rl.on("line", (line) => {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(line);
  } else if (ws.readyState === WebSocket.CONNECTING) {
    pendingQueue.push(line);
  } else {
    process.stderr.write("[bridge] ws closed, dropping message\n");
  }
});

rl.on("close", () => {
  ws.close();
  process.exit(0);
});
