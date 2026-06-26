# zeb Echo — Backend

Local Node.js + TypeScript backend for **zeb Echo**, the AI meeting assistant. It hosts the
AI pipeline (speech-to-text → question detection → response generation) and serves a
**localhost WebSocket** that the Flutter client connects to.

> Phase 1 scaffolding: the pipeline runs end-to-end against **fakes/stubs**. Real Vosk STT
> and a real LLM are not yet integrated (clearly marked `TODO`). The default LLM provider is
> Ollama, with an automatic fallback to the deterministic `FakeLlmProvider`.

## Requirements

- Node.js >= 24
- npm

## Install

```bash
cd backend
npm install
```

## Run

```bash
npm run dev        # run with tsx (watch mode)
npm run build      # compile TypeScript → dist/
npm start          # run the compiled build (dist/index.js)
```

On startup the server logs its listening address, e.g.
`[zeb-echo] WebSocket server listening on ws://127.0.0.1:8787`.

## Quality gates

```bash
npm run typecheck  # tsc --noEmit
npm run lint       # ESLint (flat config)
npm test           # node:test via tsx
```

Format with Prettier before committing (`.prettierrc`).

## Environment variables

All have safe defaults; none are secrets. Secrets (e.g. cloud LLM keys) must come from env
or a git-ignored `.env` — never committed.

| Variable        | Default                   | Description                                        |
| --------------- | ------------------------- | -------------------------------------------------- |
| `PORT`          | `8787`                    | WebSocket listen port.                             |
| `HOST`          | `127.0.0.1`               | Bind host (localhost only in Phase 1).             |
| `LLM_PROVIDER`  | `ollama`                  | Provider id: `ollama` or `fake`.                   |
| `OLLAMA_URL`    | `http://127.0.0.1:11434`  | Ollama base URL (used by `OllamaProvider`).        |
| `OLLAMA_MODEL`  | `llama3.2`                | Ollama model tag.                                  |

For development without Ollama, run with `LLM_PROVIDER=fake`.

## Architecture

```
WsGateway → SessionOrchestrator
   → TranscriptionService (Vosk; fake in Phase 1)
   → QuestionDetectionService (heuristic)
   → ResponseService → LlmProvider (Ollama default | fake)
+ latency metrics (question detected → first response token)
```

- **`src/protocol/messages.ts`** — the single source of truth for the wire protocol. The
  Dart client DTOs mirror these types.
- **`src/llm/`** — the provider-agnostic LLM layer. Each provider lives in its own module;
  no provider SDK is imported outside this directory.
- **`src/pipeline/`** — transcription, question detection, response services (interfaces +
  real/fake implementations).
- **`src/session/`** — the orchestrator that wires the pipeline and owns the session
  lifecycle.
- **`src/server/`** — the WebSocket gateway (the only layer that knows the wire format).

## Protocol overview (versioned, typed — `PROTOCOL_VERSION = 1`)

Every message carries a `type` (discriminator) and a `version`. Unknown types are ignored
forward-compatibly. Phase 1 assumes a single local client.

**Client → Backend**

- `session.start` / `session.pause` / `session.stop` — session control (JSON text frames).
- `audio.chunk` — PCM audio, sent as a **binary** WebSocket frame. Format is pinned in
  `AUDIO_FORMAT`: 16 kHz, mono, 16-bit signed little-endian PCM.

**Backend → Client**

- `transcript.partial` / `transcript.final` — transcript segments with timestamps.
- `question.detected` — a detected question + source segment reference.
- `response.token` / `response.done` — streamed LLM tokens, then completion (with first-token
  latency when measured).
- `status` — pipeline / provider / audio health.
- `error` — a structured, renderable error.

See `src/protocol/messages.ts` for the exact TypeScript definitions.
