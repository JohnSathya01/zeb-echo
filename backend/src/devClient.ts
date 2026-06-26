/**
 * Dev test client — stands in for the Flutter UI so the full pipeline can be
 * validated without building the macOS app (no Xcode required).
 *
 * Connects to the local backend, sends `session.start`, and pretty-prints every
 * ServerMessage: transcript segments, detected questions, streamed LLM tokens,
 * status, and errors. Backend-side BlackHole capture starts on session.start,
 * so just play audio (e.g. a YouTube video) and watch it flow through.
 *
 *   npm run devclient            # runs until Ctrl-C
 */
import { WebSocket } from 'ws';
import { PROTOCOL_VERSION, type ServerMessage } from './protocol/messages.js';

const URL = process.env.ZEB_WS_URL ?? 'ws://127.0.0.1:8787';

const ws = new WebSocket(URL);

// Accumulate streamed response tokens per question for readable output.
const answers = new Map<string, string>();

ws.on('open', () => {
  console.log(`[devClient] connected → ${URL}`);
  ws.send(JSON.stringify({ type: 'session.start', version: PROTOCOL_VERSION }));
  console.log('[devClient] sent session.start — play some audio now. Ctrl-C to stop.\n');
});

ws.on('message', (data) => {
  let msg: ServerMessage;
  try {
    msg = JSON.parse(data.toString()) as ServerMessage;
  } catch {
    console.log('[devClient] non-JSON frame');
    return;
  }

  switch (msg.type) {
    case 'transcript.partial':
      process.stdout.write(`\r  …partial: ${msg.segment.text}`.padEnd(80));
      break;
    case 'transcript.final':
      console.log(`\n📝 transcript: ${msg.segment.text}`);
      break;
    case 'question.detected':
      console.log(`\n❓ QUESTION [${msg.questionId}]: ${msg.text}`);
      answers.set(msg.questionId, '');
      break;
    case 'response.token': {
      const prev = answers.get(msg.questionId) ?? '';
      answers.set(msg.questionId, prev + msg.token);
      process.stdout.write(msg.token);
      break;
    }
    case 'response.done':
      console.log(
        `\n🤖 [done ${msg.questionId}]${
          msg.firstTokenLatencyMs !== undefined
            ? ` — first token in ${Math.round(msg.firstTokenLatencyMs)}ms`
            : ''
        }\n`,
      );
      break;
    case 'status':
      console.log(`ℹ️  status[${msg.domain}/${msg.state}]${msg.detail ? ` — ${msg.detail}` : ''}`);
      break;
    case 'error':
      console.log(`🛑 error[${msg.code}]: ${msg.message}`);
      break;
  }
});

ws.on('close', () => {
  console.log('[devClient] connection closed');
  process.exit(0);
});

ws.on('error', (err) => {
  console.error('[devClient] socket error:', err.message);
  process.exit(1);
});

const stop = (): void => {
  console.log('\n[devClient] stopping session…');
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify({ type: 'session.stop', version: PROTOCOL_VERSION }));
    ws.close();
  }
  setTimeout(() => process.exit(0), 300);
};
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
