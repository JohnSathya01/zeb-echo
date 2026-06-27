# zeb Echo — Phase 2 Plan: Distributable Desktop App + CI/CD

> Goal: teammates on **macOS and Windows** install a single app (Teams runs on
> desktop), it captures meeting audio locally, and the AI pipeline just works —
> no manual Node/ffmpeg setup. Code lives in one GitHub repo (`zeb-echo`) with
> CI/CD that builds installers for both OSes.

Status: PLAN (not yet implemented). Phase 1 (local dev pipeline) is working.

---

## 0. Why not web hosting (Firebase/Cloudflare)?

Teams runs as a **native desktop app**. A browser/website **cannot** capture a
native app's system audio on macOS (OS restriction). Therefore the product must
be a **desktop app**, distributed as installers — not a hosted URL. Firebase
Hosting and Cloudflare Workers do not apply to the audio app itself.

(Whisper STT + the LLM still call Cloudflare Workers AI over HTTPS — that part is
already "cloud" and stays.)

Distribution model:

```
GitHub repo (zeb-echo)
   └─ push / tag
        └─ GitHub Actions
             ├─ macOS runner  → builds zeb-echo.app / .dmg
             └─ Windows runner → builds zeb-echo.exe / .msi (installer)
                  └─ published as GitHub Release assets
                       └─ teammates download the installer for their OS
```

---

## 1. Architecture change: bundle the backend into the app

Today the Flutter client and the Node backend are **two processes started by
hand**. For a one-click app, the Flutter app must own the backend lifecycle.

**Target:** on launch, the Flutter desktop app spawns the bundled Node backend
(and ffmpeg) as a child process, waits for the WebSocket to be ready, connects,
and shuts it down on exit.

Work items:
- **Bundle a Node runtime + the compiled backend** inside the app package.
  Options (pick one in M1):
  - (a) Bundle `node` binary + `backend/dist` + `node_modules` as app resources.
  - (b) Compile the backend to a single executable (`pkg` / Node SEA / `bun build
    --compile`) so there's no separate Node install. **Recommended** — simplest
    for end users, smallest support burden.
- **Bundle `ffmpeg`** per-OS binary as an app resource (it's a CLI dependency).
  Pin a static build; document the license (ffmpeg is LGPL/GPL — use an
  LGPL/shared build and attribute).
- **Spawn + supervise** from Dart: a `BackendLauncher` that starts the executable
  on a free localhost port, health-checks the WS handshake, restarts on crash,
  and kills it on app close. Pass the port to `BackendClient`.
- **Port/handshake**: pick a free port at runtime (avoid hardcoded 8787 clashes);
  pass it to the client via the launcher. Records the §9 "startup model" decision.

Deliverable: double-click the app → backend + ffmpeg start automatically →
dashboard connects. No terminal, no `npm run dev`.

---

## 2. Cross-platform audio capture

This is the hardest part and differs by OS. The Dart `AudioCaptureService`
abstraction already exists; the native capture is what's missing.

### 2a. macOS (partly done)
- System audio still needs a **loopback device** (BlackHole) — macOS has no
  built-in system-audio capture for arbitrary apps.
- **Per-user setup remains:** each Mac teammate needs BlackHole installed + a
  Multi-Output Device with Drift Correction (the routing we fought through).
- Options to reduce that pain:
  - (a) Bundle the **BlackHole installer** and script the Multi-Output Device
    creation on first run (via `audiodevice`/CoreAudio APIs). Still needs the
    user to pick the output device.
  - (b) Move to **ScreenCaptureKit audio capture** (macOS 13+), which captures
    system/app audio **without** BlackHole or routing. **Recommended long-term**
    — removes the entire BlackHole headache. Requires native Swift + a Flutter
    platform channel, and the Screen Recording permission prompt.

### 2b. Windows (NOT built — net new)
- Decision log: *"Windows (WASAPI) still TODO."* The backend has zero Windows
  capture today.
- Implement **WASAPI loopback** capture (captures system output directly — no
  virtual device needed, unlike macOS). Plus WASAPI mic capture.
- Feed the same 16 kHz mono s16le PCM into the existing pipeline so nothing
  downstream changes.
- Likely a small native helper (C++/Rust) or an ffmpeg `dshow`/WASAPI input,
  invoked the same way `SystemAudioCapture` invokes ffmpeg today.

### 2c. Permissions (both OSes)
- macOS: Microphone + Screen Recording (for ScreenCaptureKit) prompts — surface
  in the Audio Status Indicator; handle denial gracefully.
- Windows: mic permission.

---

## 3. Secrets: the `CF_API_TOKEN` problem

Today the Cloudflare token lives in `backend/.env`. Shipping it inside an
installed app **exposes it to every teammate** (extractable from the bundle).

Options:
- (a) **Token proxy (recommended):** stand up a tiny hosted endpoint (this CAN be
  a Cloudflare Worker) that holds the secret and proxies Whisper/LLM calls. The
  app calls the proxy; the token never ships. Adds a small always-on cloud piece.
- (b) **Per-user token:** each teammate pastes their own CF token into a settings
  screen (stored in OS keychain/credential manager). No shared secret; more setup.
- (c) **Accept the risk** for an internal-only tool with a scoped, rotatable
  token. Fastest; least safe.

This is a real decision — flagging now because it affects the build.

---

## 4. GitHub repo + CI/CD

### Repo: `zeb-echo` (monorepo)
```
zeb-echo/
  client/            # Flutter desktop app
  backend/           # Node/TS backend (compiled + bundled into the app)
  .github/workflows/ # CI/CD
  CLAUDE.md
  PHASE2_PLAN.md
```
- Add a root `.gitignore` (node_modules, build/, .env, *.dmg, etc.).
- **Verify `.env` / `CF_API_TOKEN` are NOT committed** (history check before push).

### CI (every push / PR) — quality gates
- **Backend job** (ubuntu): `npm ci`, `npm run lint`, `npm run typecheck`, `npm test`.
- **Client job** (ubuntu): `flutter pub get`, `flutter analyze`, `flutter test`.
- Fast feedback; no installers built here.

### CD (on version tag `v*`) — build + release installers
- **macOS job** (`macos-latest`, has Xcode): build backend exe + bundle → 
  `flutter build macos` → package `.dmg` → upload artifact.
- **Windows job** (`windows-latest`, has VS): build backend exe + bundle → 
  `flutter build windows` → package `.msi`/`.exe` (e.g. `msix` or Inno Setup) →
  upload artifact.
- **Release job**: attach both installers to a GitHub Release for download.
- **Code signing (later):** unsigned apps trigger Gatekeeper (macOS) / SmartScreen
  (Windows) warnings. Real signing needs an Apple Developer cert ($99/yr) + a
  Windows code-signing cert. Document; teammates can right-click-open meanwhile.

---

## 5. Suggested sequencing (milestones)

| # | Milestone | Outcome | Effort |
|---|-----------|---------|--------|
| **M0** ✅ | GitHub repo + CI gates | Code on GitHub, lint/test/analyze run on push | S |
| **M1** ✅ | Bundle backend+ffmpeg, app spawns it | Double-click app → pipeline runs locally (mac) | M |
| **M2** ✅ | CD builds Mac **and** Windows installers | Downloadable installers per OS (audio mac-only) | M |
| **M3** 🔨 | Windows WASAPI capture | Windows teammates get system audio | L (built, needs Windows verify) |
| **M4** ✅ | Secrets strategy (proxy or per-user) | Token not shipped in the app | M |
| **M5** ✅ | macOS ScreenCaptureKit (drop BlackHole) | No per-user BlackHole/routing setup | L |
| **M6** | Code signing + auto-update | No Gatekeeper/SmartScreen warnings | M |

> **Status (2026-06-26):** M0–M2 + M4 implemented. The CD pipeline
> (`.github/workflows/release.yml`) builds on a `v*` tag: backend single-exe
> (universal on mac), static ffmpeg, Flutter app with **REAL_BACKEND baked in
> (no fakes ship)** + Cloudflare STT/LLM via the token-proxy Worker, bundled and
> packaged to `.dmg` (mac) / `.zip` (win), attached to a GitHub Release.
> **Not yet exercised** — the first `v*` tag is its first real run; the
> static-ffmpeg fetch URLs are the most likely first-run breakage. The proxy
> Worker (M4) is coded but **not yet deployed** (`worker/`), and `CF_GATEWAY_URL`
> must be set as a repo variable for the shipped app to reach Cloudflare.
> **Windows system audio (M3) is still not built** — Windows installs + UI + mic
> work, but no system-audio capture until M3.

Each milestone is independently shippable. M0–M2 get you *downloadable installers
fast* (mac fully working, Windows UI+mic, system-audio pending M3).

---

## 6. Open decisions (need your input before building)

1. **Backend bundling:** single compiled exe (recommended) vs. bundled Node?
2. **macOS capture:** keep BlackHole (faster) or invest in ScreenCaptureKit
   (removes per-user setup)?
3. **Secrets:** token proxy (safest) vs. per-user token vs. accept risk?
4. **Code signing:** do you have / want Apple + Windows signing certs, or ship
   unsigned for now (internal use)?
5. **Scope confirm:** this is explicitly Phase-2 (CLAUDE.md scopes Phase-1 as
   local-only). OK to proceed beyond Phase-1 scope?

---

## 7. What I can start immediately (low-risk)

- **M0**: create `zeb-echo` on GitHub, add root `.gitignore`, scrub for secrets,
  push, and add CI workflows (lint/typecheck/test/analyze). This is safe and
  reversible and unblocks everything else — no architecture change yet.
