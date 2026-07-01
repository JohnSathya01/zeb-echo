/**
 * WsGateway (CLAUDE.md §3 / §3.2). The ONLY layer that knows the wire format.
 *
 * Hosts a `ws` WebSocket server bound to localhost. For each connection it
 * builds a per-connection SessionOrchestrator (Phase 1 assumes a single local
 * client). It decodes ClientMessages (JSON text frames + binary audio frames),
 * routes them to the orchestrator, and encodes ServerMessages back to the wire.
 */
import { WebSocketServer, type WebSocket } from 'ws';
import type { AppConfig } from '../config.js';
import { AudioSourceManager } from '../audio/AudioSourceManager.js';
import { resolveAudioDevices } from '../audio/resolveDevices.js';
import { selectProvider } from '../llm/index.js';
import { CloudflareTranscriptionService } from '../pipeline/CloudflareTranscriptionService.js';
import {
  HeuristicQuestionDetectionService,
  type QuestionDetectionService,
} from '../pipeline/QuestionDetectionService.js';
import { LlmQuestionDetectionService } from '../pipeline/LlmQuestionDetectionService.js';
import { LlmResponseService } from '../pipeline/ResponseService.js';
import type { LlmProvider } from '../llm/LlmProvider.js';
import {
  FakeTranscriptionService,
  type TranscriptionService,
} from '../pipeline/TranscriptionService.js';
import {
  encodeServerMessage,
  parseClientMessage,
  PROTOCOL_VERSION,
  type ServerMessage,
} from '../protocol/messages.js';
import { SessionOrchestrator } from '../session/SessionOrchestrator.js';

export class WsGateway {
  private readonly config: AppConfig;
  private server: WebSocketServer | null = null;
  /** Auto-detected device indices (by name), filled at start(). */
  private resolvedMicIndex = '';
  private resolvedSystemIndex = '';

  constructor(config: AppConfig) {
    this.config = config;
  }

  /** Start listening. Resolves once the server is accepting connections. */
  public async start(): Promise<{ host: string; port: number }> {
    // Auto-detect avfoundation device indices by name when not explicitly set,
    // so the app works on any Mac without a hardcoded AUDIO_DEVICE_INDEX
    // (CLAUDE.md §9). Explicit env values always win. ScreenCaptureKit needs no
    // device for system audio, but the mic source still uses an avfoundation
    // device, so resolve whenever the backend captures or the mic is enabled.
    const needsDevices =
      this.config.audioSource === 'blackhole' ||
      (this.config.audioSource === 'screencapturekit' &&
        this.config.micEnabledDefault);
    if (needsDevices) {
      await this.resolveDeviceIndices();
    }

    return new Promise((resolve, reject) => {
      const server = new WebSocketServer({
        host: this.config.host,
        port: this.config.port,
      });

      server.on('connection', (socket) => this.handleConnection(socket));
      server.on('error', reject);
      server.on('listening', () => {
        resolve({ host: this.config.host, port: this.config.port });
      });

      this.server = server;
    });
  }

  /** Resolve mic/system device indices by name (explicit config wins). */
  private async resolveDeviceIndices(): Promise<void> {
    try {
      const detected = await resolveAudioDevices();
      this.resolvedSystemIndex =
        this.config.audioDeviceIndex || (detected.system ?? '');
      this.resolvedMicIndex = this.config.micDeviceIndex || (detected.mic ?? '');
      const names = detected.devices
        .map((d) => `[${d.index}] ${d.name}`)
        .join(', ');
      console.log(`[audio] devices: ${names || '(none)'}`);
      console.log(
        `[audio] using system index "${this.resolvedSystemIndex}", ` +
          `mic index "${this.resolvedMicIndex}"`,
      );
      if (this.resolvedSystemIndex === '') {
        console.warn(
          '[audio] No BlackHole/loopback device found — system audio capture ' +
            'will not work until one is installed. Mic capture still works.',
        );
      }
    } catch (err) {
      console.warn('[audio] device auto-detection failed:', err);
      // Fall back to whatever was configured (possibly empty).
      this.resolvedSystemIndex = this.config.audioDeviceIndex;
      this.resolvedMicIndex = this.config.micDeviceIndex;
    }
  }

  /** Stop the server and close all connections. */
  public stop(): Promise<void> {
    return new Promise((resolve) => {
      if (this.server === null) {
        resolve();
        return;
      }
      this.server.close(() => resolve());
      this.server = null;
    });
  }

  private handleConnection(socket: WebSocket): void {
    // Build a fresh pipeline + orchestrator per connection.
    const llmProvider = selectProvider(this.config);

    // When the backend captures audio itself (AUDIO_SOURCE=blackhole), each
    // source owns its own transcription inside the AudioSourceManager and feeds
    // labelled segments into the orchestrator — so the orchestrator gets no
    // single `transcription`. Otherwise (client-fed audio) keep the legacy
    // single transcription on the pushAudio path.
    const backendCaptures =
      this.config.audioSource === 'blackhole' ||
      this.config.audioSource === 'screencapturekit' ||
      this.config.audioSource === 'wasapi';

    const orchestrator = new SessionOrchestrator(
      {
        transcription: backendCaptures ? undefined : this.createTranscription(),
        questionDetection: this.createQuestionDetection(llmProvider),
        responseService: new LlmResponseService(llmProvider),
        llmProvider,
      },
      (message: ServerMessage) => {
        if (socket.readyState === socket.OPEN) {
          socket.send(encodeServerMessage(message));
        }
      },
    );

    const sources = backendCaptures
      ? this.createSourceManager(orchestrator, socket)
      : null;

    socket.on('message', (data: Buffer | ArrayBuffer | Buffer[], isBinary: boolean) => {
      if (isBinary) {
        // Binary frame = raw PCM audio.chunk payload (§3.2 AUDIO_FORMAT).
        orchestrator.pushAudio(toUint8Array(data));
        return;
      }
      this.handleTextFrame(data, orchestrator, socket, sources);
    });

    socket.on('close', () => {
      sources?.stop();
      orchestrator.stop();
    });

    socket.on('error', () => {
      sources?.stop();
      orchestrator.stop();
    });
  }

  /** Choose the transcription engine from config. */
  private createTranscription(): TranscriptionService {
    if (this.config.transcriptionEngine === 'cloudflare') {
      return new CloudflareTranscriptionService({
        accountId: this.config.cfAccountId,
        whisperModel: this.config.cfWhisperModel,
        apiToken: this.config.cfApiToken,
        gatewayUrl: this.config.cfGatewayUrl,
        gatewayToken: this.config.cfGatewayToken,
        windowMs: this.config.sttWindowMs,
        debug: this.config.sttDebug,
      });
    }
    return new FakeTranscriptionService();
  }

  /** Choose the question detector from config (LLM-based vs heuristic). */
  private createQuestionDetection(
    llmProvider: LlmProvider,
  ): QuestionDetectionService {
    if (this.config.questionDetector === 'llm') {
      return new LlmQuestionDetectionService(llmProvider, this.config.sttDebug);
    }
    return new HeuristicQuestionDetectionService();
  }

  /**
   * Build the backend-side multi-source capture manager (mic + system), each
   * with its own transcription tagged by speaker. Feeds labelled segments into
   * the orchestrator and forwards per-source health to the client.
   */
  private createSourceManager(
    orchestrator: SessionOrchestrator,
    socket: WebSocket,
  ): AudioSourceManager {
    const manager = new AudioSourceManager({
      micDeviceIndex: this.resolvedMicIndex,
      systemDeviceIndex: this.resolvedSystemIndex,
      micEnabled: this.config.micEnabledDefault,
      systemEnabled: this.config.systemEnabledDefault,
      systemCaptureKind:
        this.config.audioSource === 'screencapturekit'
          ? 'screencapturekit'
          : this.config.audioSource === 'wasapi'
            ? 'wasapi'
            : 'ffmpeg',
      createTranscription: () => this.createTranscription(),
    });

    manager.onSegment((segment) => orchestrator.ingestSegment(segment));

    // Surface per-source capture health (Audio Status Indicator, §4.2).
    manager.onStatus(({ source, ok, detail }) => {
      if (socket.readyState === socket.OPEN) {
        socket.send(
          encodeServerMessage({
            type: 'status',
            version: PROTOCOL_VERSION,
            domain: 'audio',
            source,
            state: ok ? 'ok' : 'degraded',
            detail,
          }),
        );
      }
    });
    return manager;
  }

  private handleTextFrame(
    data: Buffer | ArrayBuffer | Buffer[],
    orchestrator: SessionOrchestrator,
    socket: WebSocket,
    sources: AudioSourceManager | null,
  ): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(toUint8Array(data).toString());
    } catch {
      this.sendError(socket, 'bad_json', 'Message was not valid JSON.');
      return;
    }

    const message = parseClientMessage(parsed);
    if (message === null) {
      // Unknown / wrong-version message — ignore forward-compatibly (§3.2).
      return;
    }

    switch (message.type) {
      case 'session.start':
        void orchestrator.start();
        // Begin backend-side capture (if configured) once the session is live.
        sources?.start();
        break;
      case 'session.pause':
        orchestrator.pause();
        sources?.stop();
        break;
      case 'session.stop':
        sources?.stop();
        orchestrator.stop();
        break;
      case 'source.toggle':
        // Enable/disable one capture source at runtime (mic/system).
        sources?.setEnabled(message.source, message.enabled);
        break;
      case 'audio.chunk':
        // PCM normally arrives as a binary frame; a JSON audio.chunk envelope
        // carries no payload here, so there is nothing to push.
        break;
      case 'kb.set':
        // Phase 3: set/replace the session Knowledge Base.
        orchestrator.setKnowledgeBase(message.content);
        break;
      case 'response.mode':
        // Phase 3: switch auto/manual response generation.
        orchestrator.setResponseMode(message.mode);
        break;
      case 'response.generate':
        // Phase 3 (manual): generate the answer for a detected question.
        void orchestrator.generateForQuestion(message.questionId);
        break;
    }
  }

  private sendError(socket: WebSocket, code: string, messageText: string): void {
    if (socket.readyState !== socket.OPEN) {
      return;
    }
    socket.send(
      encodeServerMessage({
        type: 'error',
        version: PROTOCOL_VERSION,
        code,
        message: messageText,
      }),
    );
  }
}

/** Normalise a ws message payload to a Uint8Array. */
function toUint8Array(data: Buffer | ArrayBuffer | Buffer[]): Buffer {
  if (Array.isArray(data)) {
    return Buffer.concat(data);
  }
  if (data instanceof ArrayBuffer) {
    return Buffer.from(data);
  }
  return data;
}
