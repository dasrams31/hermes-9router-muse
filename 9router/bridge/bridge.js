#!/usr/bin/env node
/**
 * muse-bridge — OpenAI-compatible "Muse" provider for 9Router.
 *
 * The provider BEHIND this bridge is Muse (the personal AI assistant) itself.
 * There is no upstream LLM API. Instead, each chat request becomes a JOB in a
 * local queue; a scheduled worker (Muse) picks pending jobs up and posts
 * answers back. The waiting HTTP request is then completed with the answer.
 *
 * Public (Bearer <BRIDGE_KEY>):
 *   GET  /health
 *   GET  /v1/models                      -> [{id:"muse",...}]
 *   POST /v1/chat/completions            -> queues job, long-polls for answer
 *
 * Internal (same Bearer key, localhost only):
 *   GET  /internal/jobs?status=pending   -> list jobs
 *   GET  /internal/jobs/:id              -> one job
 *   POST /internal/jobs/:id/claim        -> mark claimed (avoid double work)
 *   POST /internal/jobs/:id/answer       -> {content} stores answer, wakes waiter
 *
 * Env:
 *   BRIDGE_PORT  default 18089
 *   BRIDGE_KEY   required — shared with 9Router connection + worker
 *   WAIT_MS      default 600000 (how long a chat request waits for an answer)
 *   JOBS_DIR     default <this-dir>/jobs
 *
 * Zero npm dependencies.
 */
"use strict";
const http = require("http");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const PORT = parseInt(process.env.BRIDGE_PORT || "18089", 10);
const BRIDGE_KEY = process.env.BRIDGE_KEY || "";
const WAIT_MS = parseInt(process.env.WAIT_MS || "600000", 10);
const DIR = path.dirname(process.argv[1]);
const JOBS_DIR = process.env.JOBS_DIR || path.join(DIR, "jobs");
const MODEL_ID = "muse";

if (!BRIDGE_KEY) {
  console.error("[bridge] FATAL: BRIDGE_KEY must be set");
  process.exit(1);
}
fs.mkdirSync(JOBS_DIR, { recursive: true });

// On boot: jobs left 'claimed' by a dead worker go back to pending.
for (const f of fs.readdirSync(JOBS_DIR)) {
  if (!f.endsWith(".json")) continue;
  const p = path.join(JOBS_DIR, f);
  try {
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    if (j.status === "claimed") {
      j.status = "pending";
      j.claimed_at = null;
      fs.writeFileSync(p, JSON.stringify(j));
      console.log("[bridge] re-queued", j.id);
    }
  } catch (e) {
    console.error("[bridge] bad job file", f, e.message);
  }
}

function timingSafeEqual(a, b) {
  const ab = Buffer.from(a), bb = Buffer.from(b);
  return ab.length === bb.length && crypto.timingSafeEqual(ab, bb);
}
function authorized(req) {
  const h = req.headers["authorization"] || "";
  const m = /^Bearer\s+(.+)$/.exec(h);
  return m ? timingSafeEqual(m[1], BRIDGE_KEY) : false;
}
function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
  res.end(body);
}
const err = (message, code = 500, type = "bridge_error") => ({ error: { message, type, code } });

function readBody(req, maxBytes = 5 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let n = 0;
    req.on("data", (c) => {
      n += c.length;
      if (n > maxBytes) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

const jobPath = (id) => path.join(JOBS_DIR, id + ".json");
function loadJob(id) {
  try {
    return JSON.parse(fs.readFileSync(jobPath(id), "utf8"));
  } catch {
    return null;
  }
}
function saveJob(j) {
  fs.writeFileSync(jobPath(j.id), JSON.stringify(j));
}
function listJobs(status) {
  const out = [];
  for (const f of fs.readdirSync(JOBS_DIR)) {
    if (!f.endsWith(".json")) continue;
    try {
      const j = JSON.parse(fs.readFileSync(path.join(JOBS_DIR, f), "utf8"));
      if (!status || j.status === status) out.push(j);
    } catch {}
  }
  out.sort((a, b) => a.created_at - b.created_at);
  return out;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- retry-storm guards (added 2026-09-30) ----
// 9Router gives up after ~28s while a worker needs 60-90s, so clients retry
// the same message and jobs pile up. Two guards:
//  1. Dedup: a new chat request identical to a live (pending/claimed) job
//     attaches to that job instead of queueing a duplicate.
//  2. Reaper: jobs claimed by a dead worker go back to pending; ancient
//     done jobs are deleted. (Boot already re-queues claimed jobs once.)
const DEDUP_WINDOW_MS = 10 * 60 * 1000;
const CLAIM_TIMEOUT_MS = 6 * 60 * 1000;
const DONE_RETENTION_MS = 24 * 60 * 60 * 1000;

function fingerprintMessages(messages) {
  return crypto.createHash("sha256").update(JSON.stringify(messages)).digest("hex");
}
function findLiveJob(fp) {
  const now = Date.now();
  for (const f of fs.readdirSync(JOBS_DIR)) {
    if (!f.endsWith(".json")) continue;
    try {
      const j = JSON.parse(fs.readFileSync(path.join(JOBS_DIR, f), "utf8"));
      if ((j.status === "pending" || j.status === "claimed") && j.fp === fp && now - j.created_at < DEDUP_WINDOW_MS) {
        return j;
      }
    } catch {}
  }
  return null;
}
setInterval(() => {
  const now = Date.now();
  for (const f of fs.readdirSync(JOBS_DIR)) {
    if (!f.endsWith(".json")) continue;
    const p = path.join(JOBS_DIR, f);
    try {
      const j = JSON.parse(fs.readFileSync(p, "utf8"));
      if (j.status === "claimed" && j.claimed_at && now - j.claimed_at > CLAIM_TIMEOUT_MS) {
        j.status = "pending";
        j.claimed_at = null;
        fs.writeFileSync(p, JSON.stringify(j));
        console.log("[bridge] reaper: re-queued stale claimed job", j.id);
      } else if (j.status === "done" && j.answered_at && now - j.answered_at > DONE_RETENTION_MS) {
        fs.unlinkSync(p);
      }
    } catch (e) {
      console.error("[bridge] reaper: bad job file", f, e.message);
    }
  }
}, 60 * 1000);

async function waitForAnswer(id) {
  const t0 = Date.now();
  while (Date.now() - t0 < WAIT_MS) {
    const j = loadJob(id);
    if (j && j.status === "done") return j;
    await sleep(500);
  }
  return loadJob(id);
}

function sseChunk(id, created, content, finish) {
  const delta = finish ? {} : { content };
  return (
    "data: " +
    JSON.stringify({
      id,
      object: "chat.completion.chunk",
      created,
      model: MODEL_ID,
      choices: [{ index: 0, delta, finish_reason: finish ? "stop" : null }],
    }) +
    "\n\n"
  );
}

async function handleChat(req, res) {
  let payload;
  try {
    payload = JSON.parse(await readBody(req, 2 * 1024 * 1024));
  } catch {
    return sendJson(res, 400, err("invalid JSON body", 400, "invalid_request_error"));
  }
  if (!Array.isArray(payload.messages) || payload.messages.length === 0) {
    return sendJson(res, 400, err("`messages` array is required", 400, "invalid_request_error"));
  }
  const stream = !!payload.stream;
  const messages = payload.messages.slice(-50); // keep prompt bounded
  const fp = fingerprintMessages(messages);
  const live = findLiveJob(fp);
  let id, created;
  if (live) {
    // Retry of an in-flight request: wait on the existing job instead of
    // queueing a duplicate that would overwhelm workers.
    id = live.id;
    created = Math.floor(live.created_at / 1000);
    console.log(`[bridge] dedup: attached to live job ${id}`);
  } else {
    id = "job_" + crypto.randomBytes(8).toString("hex");
    created = Math.floor(Date.now() / 1000);
    const job = {
      id,
      fp,
      model: MODEL_ID,
      messages,
      stream,
      status: "pending",
      created_at: Date.now(),
      claimed_at: null,
      answer: null,
    };
    saveJob(job);
    console.log(`[bridge] queued ${id} (${job.messages.length} msgs, stream=${stream})`);
  }

  const done = await waitForAnswer(id);
  if (!done || done.status !== "done" || typeof done.answer !== "string") {
    console.log(`[bridge] ${id} timed out waiting for worker`);
    return sendJson(res, 504, err("Muse worker did not answer in time — try again", 504, "timeout"));
  }
  const content = done.answer;
  console.log(`[bridge] ${id} answered (${content.length} chars)`);

  if (stream) {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    });
    // Emit the answer as SSE chunks so clients see progressive output.
    const parts = content.match(/[\s\S]{1,120}/g) || [""];
    for (const p of parts) res.write(sseChunk("chatcmpl-" + id, created, p, false));
    res.write(sseChunk("chatcmpl-" + id, created, "", true));
    res.write("data: [DONE]\n\n");
    res.end();
  } else {
    sendJson(res, 200, {
      id: "chatcmpl-" + id,
      object: "chat.completion",
      created,
      model: MODEL_ID,
      choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
      usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
    });
  }
}

async function handleInternal(req, res, parts) {
  // parts: ["internal","jobs", ...]
  if (parts[1] !== "jobs") return sendJson(res, 404, err("not found", 404));
  const q = new URL(req.url, "http://x").searchParams;

  if (req.method === "GET" && parts.length === 2) {
    const jobs = listJobs(q.get("status") || undefined).map((j) => ({
      id: j.id,
      model: j.model,
      status: j.status,
      created_at: j.created_at,
      claimed_at: j.claimed_at,
      n_messages: j.messages.length,
      messages: q.get("full") === "1" ? j.messages : undefined,
      answer_chars: j.answer ? j.answer.length : 0,
    }));
    return sendJson(res, 200, { object: "list", data: jobs });
  }
  if (req.method === "GET" && parts.length === 3) {
    const j = loadJob(parts[2]);
    return j ? sendJson(res, 200, j) : sendJson(res, 404, err("job not found", 404));
  }
  if (req.method === "POST" && parts.length === 4 && parts[3] === "claim") {
    const j = loadJob(parts[2]);
    if (!j) return sendJson(res, 404, err("job not found", 404));
    if (j.status !== "pending") return sendJson(res, 409, err("job not pending", 409));
    j.status = "claimed";
    j.claimed_at = Date.now();
    saveJob(j);
    return sendJson(res, 200, { id: j.id, status: j.status, messages: j.messages });
  }
  if (req.method === "POST" && parts.length === 4 && parts[3] === "answer") {
    let body;
    try {
      body = JSON.parse(await readBody(req));
    } catch {
      return sendJson(res, 400, err("invalid JSON", 400));
    }
    const j = loadJob(parts[2]);
    if (!j) return sendJson(res, 404, err("job not found", 404));
    if (typeof body.content !== "string" || !body.content) {
      return sendJson(res, 400, err("`content` string is required", 400));
    }
    j.answer = body.content;
    j.status = "done";
    j.answered_at = Date.now();
    saveJob(j);
    return sendJson(res, 200, { id: j.id, status: "done" });
  }
  return sendJson(res, 404, err("not found", 404));
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const parts = url.pathname.split("/").filter(Boolean);

  if (req.method === "GET" && url.pathname === "/health") {
    const pend = listJobs("pending");
    return sendJson(res, 200, {
      status: "ok",
      model: MODEL_ID,
      pending: pend.length,
      pending_ids: pend.map((j) => j.id),
    });
  }
  if (!authorized(req)) {
    res.writeHead(401, { "Content-Type": "application/json", "WWW-Authenticate": "Bearer" });
    return res.end(JSON.stringify(err("invalid bridge key", 401, "authentication_error")));
  }
  if (req.method === "GET" && url.pathname === "/v1/models") {
    return sendJson(res, 200, {
      object: "list",
      data: [
        {
          id: MODEL_ID,
          object: "model",
          owned_by: "muse",
          capabilities: { vision: false, tools: false, reasoning: true },
        },
      ],
    });
  }
  if (req.method === "POST" && url.pathname === "/v1/chat/completions") return handleChat(req, res);
  if (parts[0] === "internal") return handleInternal(req, res, parts);
  return sendJson(res, 404, err("not found: " + url.pathname, 404));
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[bridge] Muse provider listening on 127.0.0.1:${PORT} (model "${MODEL_ID}")`);
});
process.on("SIGTERM", () => server.close(() => process.exit(0)));
