/**
 * zeb Echo backend entrypoint. Loads config, starts the WebSocket gateway, and
 * logs the listening address. Handles graceful shutdown on SIGINT/SIGTERM.
 */
import { loadConfig } from './config.js';
import { selectProvider } from './llm/index.js';
import { WsGateway } from './server/WsGateway.js';
import { killAllCaptureProcesses } from './audio/SystemAudioCapture.js';

async function main(): Promise<void> {
  const config = loadConfig();
  const gateway = new WsGateway(config);

  const { host, port } = await gateway.start();
  console.log(`[zeb-echo] WebSocket server listening on ws://${host}:${port}`);
  console.log(`[zeb-echo] LLM provider: ${config.llmProvider}`);

  // Probe the selected provider so misconfiguration (missing token, wrong
  // account id, model unreachable) is reported loudly at startup.
  const provider = selectProvider(config);
  void provider
    .isAvailable()
    .then((ok) => {
      console.log(
        ok
          ? `[zeb-echo] Provider "${provider.id}" reachable ✓`
          : `[zeb-echo] Provider "${provider.id}" NOT reachable ✗ — check credentials/config (responses will fail).`,
      );
    })
    .catch(() => {
      console.log(`[zeb-echo] Provider "${provider.id}" health check errored.`);
    });

  const shutdown = (signal: string): void => {
    console.log(`[zeb-echo] Received ${signal}, shutting down…`);
    // Kill capture children FIRST (they hold the macOS screen-recording
    // session), synchronously, so they never outlive the backend.
    killAllCaptureProcesses();
    void gateway.stop().then(() => process.exit(0));
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  // Last-resort: whatever ends the process, take the capture children with us.
  process.on('exit', () => killAllCaptureProcesses());

  // Watchdog: when spawned by the desktop app, exit as soon as the app process
  // is gone — however it quits (clean, crash, force-quit). Without this, macOS
  // doesn't kill a child when the parent dies, so the backend (and its capture
  // helper) would linger and keep the screen-recording session alive.
  startParentWatchdog(shutdown);
}

/**
 * Poll the parent (app) PID passed via PARENT_PID; when it no longer exists,
 * trigger shutdown. No-op if PARENT_PID is unset (standalone dev runs).
 */
function startParentWatchdog(shutdown: (signal: string) => void): void {
  const raw = process.env.PARENT_PID;
  const parentPid = raw ? Number.parseInt(raw, 10) : NaN;
  if (!Number.isInteger(parentPid) || parentPid <= 0) {
    return;
  }
  const timer = setInterval(() => {
    try {
      // Signal 0 doesn't send a signal — it just checks the process exists.
      process.kill(parentPid, 0);
    } catch {
      console.log(`[zeb-echo] Parent app (pid ${parentPid}) is gone; exiting.`);
      clearInterval(timer);
      shutdown('parent-exit');
    }
  }, 2_000);
  // Don't let the watchdog keep the event loop alive on its own.
  timer.unref?.();
}

main().catch((err: unknown) => {
  console.error('[zeb-echo] Fatal startup error:', err);
  process.exit(1);
});
