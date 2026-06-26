# zeb Echo

AI-powered real-time meeting assistant. Listens to a live meeting, transcribes
it, detects questions, and generates contextual answers — running locally on the
user's desktop.

Two locally-running parts that talk over a localhost WebSocket:

- **`client/`** — Flutter desktop app (UI + native audio capture).
- **`backend/`** — Node/TypeScript backend hosting the AI pipeline
  (Cloudflare Whisper STT → question detection → provider-agnostic LLM).

See **[CLAUDE.md](CLAUDE.md)** for the full architecture, tech stack, and
conventions, and **[PHASE2_PLAN.md](PHASE2_PLAN.md)** for the desktop-app
packaging + CI/CD roadmap.

## Quick start (local dev)

```bash
# Backend (terminal 1)
cd backend && npm install && npm run dev

# Client on web/Chrome (no Xcode needed) — terminal 2
cd client && flutter pub get
flutter run -d chrome --dart-define=REAL_BACKEND=true --dart-define=BACKEND_URL=ws://127.0.0.1:8787
```

Copy `backend/.env.example` to `backend/.env` and fill in your Cloudflare
credentials before running. **Never commit `.env`.**
