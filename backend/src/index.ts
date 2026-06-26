/**
 * zeb Echo backend entrypoint. Loads config, starts the WebSocket gateway, and
 * logs the listening address. Handles graceful shutdown on SIGINT/SIGTERM.
 */
import { loadConfig } from './config.js';
import { selectProvider } from './llm/index.js';
import { WsGateway } from './server/WsGateway.js';

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
    void gateway.stop().then(() => process.exit(0));
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

main().catch((err: unknown) => {
  console.error('[zeb-echo] Fatal startup error:', err);
  process.exit(1);
});
