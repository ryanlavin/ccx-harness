#!/usr/bin/env node
/*
 * ccx-harness :: channel server
 *
 * A minimal MCP stdio server that declares the experimental
 * `claude/channel` capability and pushes notifications into the live
 * Claude Code session whenever Codex updates the harness inbox signal
 * file. Replaces the FileChanged hook approach, which only fires on
 * Claude's own Edit/Write tool calls and is invisible to external
 * processes.
 *
 * Wire format: JSON-RPC 2.0 over stdio, one message per line (LSP-style
 * newline-delimited). The MCP TS SDK uses Content-Length-header framing
 * by default, but Claude Code accepts newline-delimited too. We use the
 * simpler form so this file can stay dependency-free.
 *
 * Lifecycle:
 *   1. Claude Code spawns this process and writes an `initialize` request
 *      to stdin.
 *   2. We respond with our serverInfo + capabilities (including
 *      experimental claude/channel).
 *   3. Claude Code sends `notifications/initialized`. We then start the
 *      filesystem watcher on .ccx-harness/inbox/_signal.
 *   4. On every modify event, we read the signal, find the latest
 *      completion file, parse its YAML frontmatter for status + pr_url,
 *      and emit a `notifications/claude/channel` notification. Claude
 *      receives this as a `<channel source="...">` message in its live
 *      conversation context.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const readline = require('readline');

const PROJECT_DIR = process.env.CLAUDE_PROJECT_DIR || process.cwd();
const SIGNAL_PATH = path.join(PROJECT_DIR, '.ccx-harness/inbox/_signal');
const INBOX_DIR = path.join(PROJECT_DIR, '.ccx-harness/inbox');

const SERVER_NAME = 'ccx-harness-channel';
const SERVER_VERSION = '0.5.1';
const PROTOCOL_VERSION = '2024-11-05';

let watcherStarted = false;
let debounceTimer = null;
let lastDispatchKey = null; // "<mtimeNs>:<inode>" — dedupes by write event, not content

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function log(...args) {
  // stderr is safe (stdout is reserved for JSON-RPC)
  process.stderr.write('[ccx-harness-channel] ' + args.join(' ') + '\n');
}

function parseFrontmatter(content) {
  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return {};
  const out = {};
  m[1].split(/\r?\n/).forEach((line) => {
    const eq = line.indexOf(':');
    if (eq === -1) return;
    const k = line.slice(0, eq).trim();
    const v = line.slice(eq + 1).trim();
    if (k) out[k] = v;
  });
  return out;
}

function buildPayload(completionPath, completionContent) {
  const fm = parseFrontmatter(completionContent);
  const status = fm.status || '';
  const prUrl = fm.pr_url || '';
  const slug = path.basename(completionPath, '.md');

  let payload =
    'ccx-harness :: Codex completion received from ' +
    completionPath +
    '\n\n----- BEGIN CODEX COMPLETION -----\n' +
    completionContent +
    '\n----- END CODEX COMPLETION -----';

  if (status === 'DONE' && prUrl && prUrl !== 'none') {
    payload +=
      '\n\n================================================================\n' +
      'AUTOMATIC VERIFICATION TRIGGER\n' +
      '================================================================\n\n' +
      'Status is DONE and a PR is open. The user has pre-authorized auto-merge on\n' +
      'two-reviewer convergence. Do not ask for confirmation; proceed now:\n\n' +
      '1. Follow the ccx-harness :: verify skill protocol immediately.\n' +
      '2. Feature slug: ' +
      slug +
      '\n' +
      '3. PR URL: ' +
      prUrl +
      '\n' +
      '4. Dispatch two parallel Opus reviewers (model: "opus", subagent_type: ' +
      '"general-purpose") in a single message. Same prompt, same inputs.\n' +
      '5. Apply the convergence decision rules. Auto-merge on both-MERGE.\n' +
      '6. Surface the verdicts to the user either way.';
  } else if (status === 'DONE' && (!prUrl || prUrl === 'none')) {
    payload +=
      '\n\nNOTE: Codex reports DONE but pr_url is missing or "none". Verification ' +
      'cannot run without a PR. Surface this to the user; likely a `gh` auth issue ' +
      'or Codex skipped the PR-open step.';
  }

  return { payload, status, prUrl, slug };
}

function processSignalChange(reason) {
  // Dedupe by write identity (inode + nanosecond mtime), NOT by content.
  // Content-based dedupe was a bug: it suppressed legitimate re-dispatches that
  // happen to write the same `latest=<slug>.md` line. mtime+inode uniquely
  // identifies a write event regardless of content.
  let stat;
  try {
    stat = fs.statSync(SIGNAL_PATH);
  } catch (e) {
    log('signal stat failed:', e.message);
    return;
  }
  const dispatchKey = `${stat.mtimeMs}:${stat.ino}`;
  if (dispatchKey === lastDispatchKey) return; // same physical write event
  lastDispatchKey = dispatchKey;

  let signalContent = '';
  try {
    signalContent = fs.readFileSync(SIGNAL_PATH, 'utf8');
  } catch (e) {
    log('signal read failed:', e.message);
    return;
  }
  if (!signalContent.trim()) return;

  const m = signalContent.match(/^latest=(.+)$/m);
  if (!m) {
    log('signal has no latest= line, ignoring');
    return;
  }
  const latestFile = m[1].trim().replace(/[\r\n ]+$/g, '');
  const completionPath = path.join(INBOX_DIR, latestFile);

  let completionContent;
  try {
    completionContent = fs.readFileSync(completionPath, 'utf8');
  } catch (e) {
    log('completion read failed:', completionPath, e.message);
    return;
  }

  const { payload, status, prUrl, slug } = buildPayload(completionPath, completionContent);

  send({
    jsonrpc: '2.0',
    method: 'notifications/claude/channel',
    params: {
      content: payload,
      meta: {
        kind: 'codex_completion',
        feature: slug,
        status,
        pr_url: prUrl,
        completion_path: completionPath,
        trigger: reason,
      },
    },
  });
  log('pushed completion for', slug, 'status=' + status, 'pr_url=' + prUrl);
}

function startWatcher() {
  if (watcherStarted) return;
  watcherStarted = true;

  // Ensure inbox dir exists (SessionStart hook should have created it, but be defensive)
  try {
    fs.mkdirSync(INBOX_DIR, { recursive: true });
  } catch (e) {
    // ignore
  }

  // Seed the dispatch key from the current file so we don't fire on the existing
  // state at startup. A signal file that already exists from a prior session
  // should not retrigger the channel on each restart.
  try {
    const stat = fs.statSync(SIGNAL_PATH);
    lastDispatchKey = `${stat.mtimeMs}:${stat.ino}`;
  } catch (e) {
    lastDispatchKey = null;
  }

  // Watch the inbox dir; fs.watch on a file alone can lose events when the file
  // is replaced (rather than modified in place). Watching the parent dir and
  // filtering on basename is more robust on macOS.
  //
  // Debounce coalesces rapid double-fires (macOS often emits two events per
  // write). Window must be short enough that real back-to-back dispatches still
  // each fire; 100ms is comfortable since signal writes are not that close.
  try {
    fs.watch(INBOX_DIR, { persistent: true }, (eventType, filename) => {
      if (!filename) return;
      if (filename !== '_signal') return;
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        debounceTimer = null;
        processSignalChange(eventType);
      }, 100);
    });
    log('watching', SIGNAL_PATH);
  } catch (e) {
    log('failed to start watcher:', e.message);
  }
}

function handleRequest(msg) {
  if (msg.method === 'initialize') {
    send({
      jsonrpc: '2.0',
      id: msg.id,
      result: {
        protocolVersion: PROTOCOL_VERSION,
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        capabilities: {
          experimental: {
            'claude/channel': {},
          },
        },
        instructions:
          'Codex completion notifications arrive as <channel source="' +
          SERVER_NAME +
          '"> messages. When you receive one with kind=codex_completion and ' +
          'status=DONE, follow the embedded verification trigger automatically. ' +
          'The user has pre-authorized auto-merge on two-reviewer convergence.',
      },
    });
  } else if (msg.method === 'notifications/initialized') {
    startWatcher();
  } else if (msg.method === 'ping') {
    send({ jsonrpc: '2.0', id: msg.id, result: {} });
  } else if (msg.method === 'shutdown') {
    send({ jsonrpc: '2.0', id: msg.id, result: null });
  } else if (msg.method === 'exit') {
    process.exit(0);
  } else if (msg.id !== undefined) {
    // Unknown request: respond with method-not-found
    send({
      jsonrpc: '2.0',
      id: msg.id,
      error: { code: -32601, message: 'Method not found: ' + msg.method },
    });
  }
  // Unknown notifications are silently dropped per JSON-RPC spec.
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  const s = line.trim();
  if (!s) return;
  let msg;
  try {
    msg = JSON.parse(s);
  } catch (e) {
    log('invalid JSON on stdin:', s.slice(0, 120));
    return;
  }
  try {
    handleRequest(msg);
  } catch (e) {
    log('handler error:', e.message);
  }
});

rl.on('close', () => {
  process.exit(0);
});

// SIGTERM/SIGINT clean exit
process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
