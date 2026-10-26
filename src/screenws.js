// screenws - WebSocket <-> stdio bridge for screenbox.ps1
//
// WHY THIS FILE EXISTS. screenbox has to run in the session a person is logged into:
// accessibility returns an empty tree from session 0 and does not raise. An MCP client
// speaks stdio to a child process it started, and that child lands in the client's
// session. So the two ends cannot meet directly, and this relays between them: it
// runs inside the interactive session (as a scheduled task), listens on loopback, and
// forks one screenbox process per WebSocket connection.
//
// EVERY FAILURE IS LOGGED AND REPORTED. The first version logged only "conn" and
// "listen", so a spawn failure looked exactly like a protocol failure: the client saw
// `close 1006` and nothing said why. That is the same silent-success shape this
// project exists to remove, arriving through the transport.

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const MODULES = 'C:/tc/uiaws/node_modules';
const { WebSocketServer } = require(path.join(MODULES, 'ws'));

const PS_SCRIPT = process.env.SCREENBOX_PS || 'C:/tc/screenbox/screenbox.ps1';
const PORT = Number(process.env.SCREENBOX_PORT || 9400);
const LOG = process.env.SCREENBOX_LOG || 'C:/tc/screenbox/s.log';

function log(msg) {
  const line = new Date().toISOString() + ' ' + msg + '\n';
  try { fs.appendFileSync(LOG, line) } catch (e) { /* logging must never throw */ }
}

const server = new WebSocketServer({ host: '127.0.0.1', port: PORT });

server.on('error', err => {
  // EADDRINUSE is the common one: an orphaned node from a previous run still holds the
  // port. Say so instead of dying with an unhandled exception and no log line.
  log('SERVER ERROR ' + (err.code || '') + ' ' + err.message);
  if (err.code === 'EADDRINUSE') {
    log('port ' + PORT + ' is already held; kill the process listening on it first');
  }
});

server.on('listening', () => log('listening on 127.0.0.1:' + PORT + ' -> ' + PS_SCRIPT));

server.on('connection', (ws, req) => {
  log('connection from ' + (req.socket.remoteAddress || '?'));

  const child = spawn('powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', PS_SCRIPT],
    { windowsHide: true });

  // WITHOUT THIS HANDLER A MISSING OR UNRUNNABLE SCRIPT IS INVISIBLE: 'error' fires on
  // the ChildProcess and, with no listener, the failure never reaches the log.
  child.on('error', err => {
    log('SPAWN FAILED: ' + err.message + ' (script=' + PS_SCRIPT + ')');
    try { ws.close(1011, 'spawn failed: ' + err.message) } catch (e) { }
  });

  let buffer = '';
  child.stdout.on('data', chunk => {
    buffer += chunk;
    let i;
    while ((i = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, i);
      buffer = buffer.slice(i + 1);
      if (line.trim() && ws.readyState === 1) ws.send(line);
    }
  });

  child.stderr.on('data', chunk => log('stderr: ' + String(chunk).trim()));

  ws.on('message', raw => {
    const text = String(raw).trim();
    if (!text) return;
    if (child.stdin.writable) child.stdin.write(text + '\n');
    else log('child stdin is not writable; dropped a message');
  });

  ws.on('close', () => {
    log('connection closed');
    try { child.kill() } catch (e) { }
  });

  child.on('exit', (code, signal) => {
    log('child exited code=' + code + ' signal=' + signal);
    try { ws.close() } catch (e) { }
  });
});

process.on('uncaughtException', err => {
  log('UNCAUGHT ' + err.message);
  process.exit(1);
});
