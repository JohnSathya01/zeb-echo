# CLAUDE.md — zeb Echo (Phase 1 MVP)

> Development requirements and engineering guidance for **zeb Echo**, an AI-powered
> real-time meeting assistant. This file is the source of truth for scope, architecture,
> tech stack, and conventions. Keep it updated as the project evolves.

---

## 1. Product Overview

**zeb Echo** listens to live meetings, transcribes the conversation, detects questions
being asked, and generates intelligent contextual responses in real time — all running
**locally** on the user's desktop.

The system is split into two locally-running parts:
- a **Flutter desktop client** (UI + native audio capture), and
- a **local TypeScript/Node backend** that hosts the AI pipeline (Vosk STT, question
  detection, and the provider-agnostic LLM layer).

Both run on the same machine in Phase 1; they communicate over a local connection
(default: **WebSocket** on `localhost`). Nothing is deployed to a server.

**Phase 1 is a lightweight, cost-effective MVP** whose only goal is to validate the
end-to-end pipeline:

```
        Flutter client (UI + native audio capture)
                          │  PCM audio  ▲  transcript / questions / response tokens
                          ▼             │  (WebSocket, localhost)
        Local TypeScript/Node backend (the pipeline)
Meeting Audio  →  Speech-to-Text  →  Question Detection  →  AI Response  →  (stream to UI)
   (captured         (Vosk,             (local logic /        (LlmProvider:
    in Flutter)       offline, Node)     lightweight model)    Ollama/Bedrock/OpenAI…)
```

### Success criteria for Phase 1
- The full pipeline works end-to-end on **both macOS and Windows**: a single Flutter client codebase + the local Node backend.
- Audio is captured (in the Flutter client) from **both system output and microphone** simultaneously and streamed to the backend.
- Transcription and question detection run **offline / locally** in the Node backend.
- Response generation works through a **provider-agnostic LLM layer**; the Phase-1 default provider is **local (Ollama)** for cost/privacy, but Bedrock / OpenAI / others can be selected via config without touching app code.
- Acceptable **response latency** for live use (target: question → response start within a few seconds; measure and record actual numbers).
- Clean, low-distraction dark UI usable during a live call.

### Explicitly OUT of scope for Phase 1
Do **not** build these unless the requirement changes:
- RAG pipelines
- Vector databases / embeddings stores
- Enterprise integrations (calendar, CRM, SSO)
- Multi-user / cloud sync / accounts
- Mobile (iOS/Android) or web targets

If a task seems to require an out-of-scope capability, stop and confirm scope before implementing.

---

## 2. Tech Stack

| Concern | Choice | Notes |
|---|---|---|
| Client framework | **Flutter (desktop)** | Single codebase → macOS + Windows. UI + native audio capture only. |
| Client language | **Dart** (app) + platform channels | Native code only where unavoidable (audio capture). |
| Backend runtime | **Node.js + TypeScript** | Runs locally on the same machine; hosts the AI pipeline. Strict TS. |
| Client ↔ backend transport | **WebSocket (localhost)** | Bidirectional streaming: PCM audio up, transcript/questions/response tokens down. |
| Speech-to-text | **Vosk** (in the Node backend) | Offline, on-device; runs continuously on the incoming audio stream. |
| LLM | **Provider-agnostic** (in the Node backend) | Backend talks to a single `LlmProvider` interface; concrete providers (Ollama, AWS Bedrock, OpenAI, …) are pluggable and swappable via config. **Local (Ollama) is the Phase-1 default**, but no code outside the provider layer may assume a specific backend. |
| Audio capture | Platform-specific (Flutter/native) | System output loopback + microphone input. |
| Client state management | TBD — pick one and document it (see §6) | Recommend `riverpod` or `bloc`; do not mix. |

> **Before writing integration code**, confirm the concrete versions/runtimes:
> Flutter SDK version, Node version, Vosk Node binding, the WebSocket library, and the
> default LLM runtime + model. Record decisions in §9 (Decision Log).

---

## 3. Architecture

Two locally-running processes with a clear one-directional data flow. The Flutter client
owns the UI and native audio capture; the Node backend owns the entire AI pipeline. They
are decoupled by a streaming WebSocket protocol — neither side reaches into the other's
internals.

```
╔═══════════════ FLUTTER CLIENT (Dart) ═══════════════╗
║ Presentation (widgets)                               ║
║  Dashboard · Transcript · Questions · Responses · …  ║
║                      ▲                               ║
║          streams / state (UI never touches sockets)  ║
║                      │                               ║
║ Client app layer:  BackendClient (WebSocket)         ║
║  + AudioCaptureService (native: mic + system loopback)║
╚════════════════════▲═══════════│════════════════════╝
       transcript /  │           │  PCM audio chunks
       questions /   │           ▼  + control (start/pause/stop)
       response tokens│   WebSocket (localhost)
╔════════════════════│═══════════▼════════════════════╗
║ NODE BACKEND (TypeScript) — the pipeline             ║
║  WsGateway → SessionOrchestrator                     ║
║    → TranscriptionService (Vosk)                     ║
║    → QuestionDetectionService                        ║
║    → ResponseService → LlmProvider                   ║
║         (Ollama default | Bedrock | OpenAI | …)      ║
║  + latency metrics                                   ║
╚══════════════════════════════════════════════════════╝
```

### Client-side contracts (Dart abstractions)
- `AudioCaptureService` — captures mic + system-audio natively; emits PCM chunks; exposes per-source status. Mixes/handles both sources.
- `BackendClient` — owns the WebSocket: streams audio + control messages up; exposes inbound streams of transcript segments, detected questions, and response tokens. The UI binds to these; it must NOT know about Vosk, the LLM, or the wire format beyond typed DTOs.

### Backend-side contracts (TypeScript interfaces)
- `WsGateway` — accepts the client connection; decodes/encodes the protocol (§3.2); routes to the orchestrator. The only layer that knows the wire format.
- `TranscriptionService` — consumes audio chunks, emits partial + final transcript segments (with timestamps). Vosk-backed.
- `QuestionDetectionService` — consumes transcript segments, emits detected questions.
- `ResponseService` — consumes detected questions (plus bounded recent transcript context), emits response tokens. Delegates generation to an injected `LlmProvider` — it must NOT know which backend is in use.
- `LlmProvider` — the **provider-agnostic LLM interface** (see §3.1). Concrete impls: `OllamaProvider`, `BedrockProvider`, `OpenAiProvider`, … plus a `FakeLlmProvider` for tests.
- `SessionOrchestrator` — wires the pipeline, owns session lifecycle (start/pause/stop), and records latency metrics.

Every service (both sides) is an **interface** with a real implementation and a
**fake/mock**, so the UI can run against a fake backend and the backend pipeline can be
tested without audio hardware or a running LLM.

### 3.1 LLM Provider Abstraction (provider-agnostic)

Lives in the **Node backend**. The LLM must be **fully swappable**: backend pipeline code
depends only on the `LlmProvider` interface — never on Ollama, Bedrock, OpenAI, or any SDK
directly. Adding a new backend = adding one new class, no changes elsewhere.

```ts
/** The single seam every backend implements. */
export interface LlmProvider {
  readonly id: string;                       // e.g. "ollama", "bedrock", "openai"

  /** Stream response tokens (preferred — lowest perceived latency). */
  generate(request: LlmRequest): AsyncIterable<string>;

  /** Liveness / reachability check (model loaded? endpoint reachable? creds valid?). */
  isAvailable(): Promise<boolean>;
}

export interface LlmRequest {
  prompt: string;                            // the detected question
  context: TranscriptSegment[];              // bounded recent conversation
  params: LlmParams;                         // temperature, maxTokens, etc.
}
```

**Rules:**
- Provider is chosen at runtime via **config** (config file / env), with **Ollama (local) as the Phase-1 default**.
- Each provider owns its own config (endpoint URL, model name, region, API keys) and its own dependencies (SDK/HTTP). Keep them in separate modules so they're independently testable and optional.
- **Secrets** (API keys, AWS creds) come from env / a secrets file that is git-ignored — never hardcoded, never committed.
- Streaming is the contract; if a backend can't stream, wrap its single response as a one-item async iterable.
- A `FakeLlmProvider` (deterministic canned responses) is the default in tests and for client/UI development.
- Failures (network down, auth error, model not pulled) are reported to the client as a clear status, not a crash; the session keeps running.
- Switching providers must require **no code changes outside the provider layer**.

> Note: cloud providers (Bedrock/OpenAI) make network calls and may incur cost — they are
> opt-in. Phase-1's default keeps everything local; the abstraction simply ensures we're
> not locked in.

### 3.2 Client ↔ Backend Protocol

A small, **versioned, typed** message protocol over the localhost WebSocket. Keep messages
as discriminated unions; share the type definitions as the single source of truth (a JSON
schema or a shared spec the Dart DTOs mirror).

**Client → Backend**
- `session.start` / `session.pause` / `session.stop` — control.
- `audio.chunk` — binary PCM frame (define sample rate, channels, encoding once and pin it).

**Backend → Client**
- `transcript.partial` / `transcript.final` — transcript segments with timestamps.
- `question.detected` — a detected question (+ source segment ref).
- `response.token` / `response.done` — streamed LLM tokens, then completion.
- `status` — pipeline/provider/audio health (e.g. provider unavailable, model loading).
- `error` — structured error the client can render.

Rules: every message carries a `type` and protocol `version`; unknown types are ignored
forward-compatibly; the backend assumes a single local client in Phase 1.

---

## 4. Feature Requirements

### 4.1 Core functionality
- [ ] Cross-platform desktop **client** build for macOS and Windows from one Flutter codebase.
- [ ] Local **Node/TypeScript backend** that runs the pipeline and serves the WebSocket.
- [ ] Real-time capture (in the client) of **system audio output** AND **microphone input**, concurrently, streamed to the backend.
- [ ] Live speech-to-text transcription in the backend (partial results streamed to and shown in the client as they arrive).
- [ ] Question detection from the ongoing transcript (backend).
- [ ] AI response generation via the provider-agnostic `LlmProvider` (default: local Ollama), using recent conversation as context (backend), streamed to the client.
- [ ] Real-time display of all of the above in the UI.

### 4.2 UI components
| Component | Requirement |
|---|---|
| **Meeting Dashboard** | Central workspace; hosts all panels below. |
| **Live Transcript Panel** | Streams the ongoing transcript in real time; auto-scrolls; readable. |
| **Detected Question Panel** | Highlights questions identified from participants. |
| **AI Response Panel** | Shows generated responses instantly (stream if possible). |
| **Audio Status Indicator** | Live status of mic + system-audio connections (connected/error/levels). |
| **Session Controls** | Start, Pause, Stop the assistance session. |

### 4.3 Non-functional requirements
- **Latency:** instrument and surface end-to-end time from question-detected → first response token, including the WebSocket hop. This is a primary Phase-1 validation metric.
- **Privacy:** audio and transcription stay on-device (client + local backend; the socket is localhost-only). The LLM stays local by default (Ollama); selecting a cloud provider (Bedrock/OpenAI) is the only path that sends data off-device, and that choice is explicit and config-driven.
- **Resilience:** if mic/system audio fails, or the backend connection drops, the client must reflect it and not crash; the client should reconnect to the backend automatically.
- **Performance:** the client UI thread stays responsive — audio capture and socket I/O off the main isolate; heavy ML work lives in the backend.
- **Startup:** define how the backend is launched and discovered (spawned by the client vs. run separately) and the port/handshake. Record in §9.

---

## 5. UI / Theme Specification

Design language: modern, minimal, enterprise, **premium dark theme**, low-distraction,
high readability for fast decisions during calls — matched to the **real zeb brand**
(zeb.co): a dark green-charcoal canvas, a lime/sage green accent, warm cream text, and a
terracotta secondary accent.

> **Correction (2026-06-26):** the original brief listed electric-blue-on-pure-black
> (`#0073E6` / `#000000`, white text). That did NOT match the actual zeb brand it claimed
> to be "inspired by." The tokens below are the corrected, brand-accurate values and are
> the source of truth; the implementation in `client/lib/theme/app_colors.dart` mirrors them.

### Theme tokens (define these centrally in a `theme/` module — never hardcode hex in widgets)
| Token | Value | Notes |
|---|---|---|
| Primary Background | `#1A211D` | zeb's dark green-charcoal hero canvas |
| Deepest Surface (chrome/bars) | `#11160F` | near-black green |
| Secondary Background / Surface | `#222B26` | raised panels |
| Elevated Surface | `#2B342E` | chips, hovered cards |
| Primary Text | `#F0EDE4` | warm cream/paper (not pure white) |
| Secondary Text | `#A7B0A6` | desaturated sage gray |
| Accent (highlights/actions) | `#B6E08A` | zeb signature lime/sage green |
| On-Accent (text/icons on accent) | `#15200F` | dark — the accent is light |
| Secondary Accent | `#C4794A` | terracotta, warm emphasis |
| Border / Divider | `#313A33` | subtle green-tinted line |

### Design principles
- Clean, minimal dashboard layout.
- Premium dark aesthetic; the **lime/green accent used sparingly** for actions/highlights/active state, with terracotta as a warm secondary.
- zeb's **serif-italic emphasis** for accented words (e.g. the "Echo" in the wordmark).
- Because the accent is light, content placed on it uses the dark **on-accent** token (never white).
- Low-distraction, optimized for use during a live meeting.
- Smooth, responsive interactions.
- High contrast / readability.

---

## 6. Project Conventions

> Fill in / confirm these as the codebase is scaffolded. The agent must follow whatever
> is established here and keep it consistent.

**Repository:** monorepo with two top-level packages — `client/` (Flutter) and
`backend/` (Node/TypeScript) — plus a shared place for the protocol type definitions
(§3.2). Document the exact layout once scaffolded.

**Client (Flutter / Dart)**
- **Directory layout:** feature-first or layer-first — pick one and document it.
- **State management:** pick ONE (`riverpod` recommended) and use it everywhere.
- **Naming:** Dart conventions — `lowerCamelCase` members, `UpperCamelCase` types, `snake_case.dart` files.
- **Theming:** all colors/spacing/typography come from theme tokens; no magic values in widgets.
- **Services:** programmed to interfaces; real + fake implementations.
- **Platform code:** isolate native code behind platform channels / FFI with a Dart-side abstraction.
- **Linting/format:** `flutter_lints` (or `very_good_analysis`); keep `flutter analyze` clean; `dart format` before committing.

**Backend (Node / TypeScript)**
- **Strict TypeScript** (`strict: true`); no `any` without justification.
- **Services programmed to interfaces** (§3); real + fake implementations.
- **Provider isolation:** each `LlmProvider` in its own module; no cross-imports of provider SDKs outside that module.
- **Linting/format:** ESLint + Prettier; keep the lint clean; format before committing.
- **No secrets in source;** load from env / git-ignored config.

---

## 7. Common Commands

> Placeholder commands — update once both packages are scaffolded.

```bash
# --- Backend (backend/) ---
npm install            # or pnpm/yarn — pick one and document it
npm run dev            # run the local backend (WebSocket server + pipeline)
npm run lint           # ESLint
npm run typecheck      # tsc --noEmit
npm test               # backend tests

# --- Client (client/) ---
flutter pub get
flutter run -d macos
flutter run -d windows
flutter analyze
dart format .
flutter test
flutter build macos
flutter build windows
```

Run the **backend** locally before running the client (until client-spawns-backend is wired).
Always run the lint/typecheck/test gates for **both** packages before declaring work done.

---

## 8. Working Agreements (for the AI agent)

- **Stay in Phase-1 scope.** If a task implies an out-of-scope item (§1), confirm first.
- **Confirm unknowns before integrating.** The exact Vosk Node binding, WebSocket library,
  and default LLM runtime are not yet pinned — verify the chosen approach (and that it
  exists / is maintained) before writing integration code against it.
- **Respect the client/backend boundary.** The UI never embeds pipeline logic; the backend
  never embeds UI concerns. They communicate only through the typed protocol (§3.2).
- **Never bind to a specific LLM backend outside the provider layer.** All generation goes
  through `LlmProvider` (§3.1). Adding Bedrock/OpenAI/etc. must be a new provider class only.
- **Decouple pipeline from UI.** Build against the service interfaces in §3; use the fake
  backend / fakes so the UI can be developed and tested without audio hardware or a running LLM.
- **Measure latency** at each pipeline stage from the start — it's a core success metric.
- **Respect the theme system** — no hardcoded colors.
- **Keep the UI thread responsive** — heavy work off the main isolate.
- **Match surrounding code** in style, naming, and structure once a pattern exists.
- Run the quality gates (§7) before reporting completion; report real results.

---

## 9. Decision Log

> Record concrete technical decisions here as they're made (date — decision — rationale).
> Examples to resolve early:

- [x] Flutter SDK / Dart version pinned: **Flutter 3.44.4 stable / Dart 3.12.2** (installed via Homebrew cask, 2026-06-26). `client/` builds clean: `flutter analyze` → 0 issues, `flutter test` → passing.
- [ ] Node version + package manager (npm / pnpm / yarn): **Node 24 + npm** (in use).
- [ ] WebSocket library (e.g. `ws`) + audio chunk format (sample rate / channels / encoding): …
- [x] STT engine: **Cloudflare Whisper** `@cf/openai/whisper-large-v3-turbo` (`CloudflareTranscriptionService`), NOT Vosk — chosen to keep local memory near-zero. Buffers PCM into ~4s rolling windows, wraps as WAV, POSTs to Workers AI. `TRANSCRIPTION_ENGINE=cloudflare|fake`. Verified end-to-end 2026-06-26 (spoken audio → exact transcript → question → LLM answer).
- [x] System-audio capture (macOS): **ffmpeg avfoundation → backend** (`SystemAudioCapture`), 16kHz mono s16le PCM piped into the pipeline. `AUDIO_SOURCE=blackhole`, `AUDIO_DEVICE_INDEX=<n>` (`npm run devices` to list). Note: this machine already exposes a `Microsoft Teams Audio` input device (index 1) — may avoid needing BlackHole. Windows (WASAPI) still TODO.
- [x] Backend startup model (2026-06-26): **client-spawns-backend** in the packaged app. A Dart `BackendLauncher` (`client/lib/services/backend_launcher*.dart`) picks a **free localhost port** (bind :0), spawns the single backend exe with `PORT`/`HOST`/`FFMPEG_PATH` env, **polls the port until ready**, hands the dynamic `ws://127.0.0.1:<port>` to `BackendClient`, auto-restarts on crash (max 3), and **kills it on app exit** (detached lifecycle). Desktop-only via conditional import (`_io`/`_stub`) so web still compiles; web/dev still uses a separately-run backend via `--dart-define=BACKEND_URL=`. Toggle spawning with `--dart-define=SPAWN_BACKEND=false`. Verified end-to-end against the real exe (dynamic port, ready, graceful SIGTERM).
- [x] Default LLM provider + model: **Cloudflare Workers AI** `@cf/meta/llama-4-scout-17b-16e-instruct` for live testing (2026-06-26). Ollama remains the offline option (still a stub); `fake` for dev.
- [x] Which providers ship in Phase 1 + selection: **ollama | cloudflare | fake**, selected via `LLM_PROVIDER` env. `CloudflareProvider` streams via Workers AI SSE.
- [x] Where provider secrets live: **env / git-ignored `.env`** (Node `--env-file`). `CF_API_TOKEN` is never committed; `.env.example` documents the keys. `CF_ACCOUNT_ID` is config, token is secret.
- [x] Shipped-app secrets (2026-06-26): **token-proxy Worker** (`worker/`, CLAUDE.md §9 decision). When `CF_GATEWAY_URL` is set, BOTH the LLM (`CloudflareProvider`) and STT (`CloudflareTranscriptionService`) route Workers AI calls through the proxy and send **no CF token** — so the desktop app ships no secret and `CF_API_TOKEN` can be blank. The single seam is `backend/src/cloudflare/access.ts` (direct vs. proxy: endpoint + auth header). Optional `CF_GATEWAY_TOKEN` (matches the Worker's `PROXY_SHARED_SECRET`) gates the proxy so it isn't an open relay. Worker holds `CF_API_TOKEN`/`CF_ACCOUNT_ID` as `wrangler secret`s; deploy steps in `worker/README.md`. **Not yet deployed** — code ready, awaiting a `wrangler deploy`.
- [ ] How question vs. response context window is bounded: …
- [ ] Client state management library: …
- [ ] Directory layout (monorepo `client/` + `backend/`; feature-first vs. layer-first inside client): …
- [ ] How protocol types are shared between Dart and TS (JSON schema / codegen / hand-mirrored): currently **hand-mirrored** — `backend/src/protocol/messages.ts` is the source of truth, `client/lib/protocol/messages.dart` mirrors it. Codegen is a future improvement (drift caused 4 mismatches once already).
- Pinned protocol contract (2026-06-26, keep both files identical on these): `version` is the **number** `1` (not a string — backend drops mismatches); `question.detected` carries **flat** `questionId`/`text`/`sourceSegmentId` (no nested object); `response.done` latency field is `firstTokenLatencyMs`; `status` carries `domain` (`pipeline|provider|audio`) + `state` (`ok|starting|degraded|unavailable`) + optional `detail`.

---

## 10. Open Risks / Notes

- **System audio capture is the hardest platform piece.** macOS requires a loopback
  mechanism (e.g. a virtual audio device / ScreenCaptureKit audio) and Windows uses WASAPI
  loopback — these differ significantly and need native work in the Flutter client.
  Prototype this first to de-risk the MVP.
- **Streaming audio over the socket** adds latency and bandwidth vs. in-process. Pin the
  chunk size/format early and measure the localhost hop's contribution to end-to-end latency.
- **Local LLM latency on consumer hardware** is the main UX risk — validate with the
  target model early and record numbers.
- **Two processes = more moving parts.** Backend lifecycle (start/stop/crash/reconnect)
  and version mismatch between client and backend protocol must be handled deliberately.
- **Permissions:** mic and screen/audio capture require OS permission prompts on macOS;
  handle and surface these gracefully in the Audio Status Indicator.
