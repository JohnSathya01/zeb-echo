/**
 * Auto-resolve avfoundation audio capture device indices BY NAME, so the app
 * works on any Mac without a hardcoded AUDIO_DEVICE_INDEX (CLAUDE.md §9 — the
 * index varies per machine; hardcoding breaks the "every system" goal).
 *
 * ffmpeg's `-list_devices` prints lines like:
 *   [AVFoundation indev @ 0x..] [0] BlackHole 2ch
 *   [AVFoundation indev @ 0x..] [1] MacBook Pro Microphone
 * We parse those, then match the system source to a loopback device (BlackHole)
 * and the mic source to the first non-loopback input.
 */
import { listAudioDevices } from './SystemAudioCapture.js';

export interface AudioDevice {
  readonly index: string;
  readonly name: string;
}

/** Parse ffmpeg's avfoundation device listing into {index, name} entries. */
export function parseAudioDevices(listing: string): AudioDevice[] {
  const devices: AudioDevice[] = [];
  // Only the audio section: lines after "AVFoundation audio devices:".
  const audioStart = listing.indexOf('AVFoundation audio devices:');
  const scope = audioStart >= 0 ? listing.slice(audioStart) : listing;
  const re = /\[(\d+)\]\s+(.+?)\s*$/gm;
  let match: RegExpExecArray | null;
  while ((match = re.exec(scope)) !== null) {
    const index = match[1];
    const name = match[2];
    if (index !== undefined && name !== undefined) {
      devices.push({ index, name: name.trim() });
    }
  }
  return devices;
}

/** Names (lowercased substrings) that indicate a system-audio loopback device. */
const LOOPBACK_HINTS = ['blackhole', 'soundflower', 'loopback', 'aggregate'];

/** True if a device name looks like a virtual loopback (system-audio) device. */
function isLoopback(name: string): boolean {
  const n = name.toLowerCase();
  return LOOPBACK_HINTS.some((h) => n.includes(h));
}

/**
 * Pick the system-audio (loopback) device index, or null if none is present.
 * Prefers BlackHole; falls back to any loopback-looking device.
 */
export function pickSystemDeviceIndex(devices: AudioDevice[]): string | null {
  const blackhole = devices.find((d) => d.name.toLowerCase().includes('blackhole'));
  if (blackhole) {
    return blackhole.index;
  }
  const loopback = devices.find((d) => isLoopback(d.name));
  return loopback ? loopback.index : null;
}

/**
 * Pick the microphone device index: the first NON-loopback input (typically the
 * built-in mic at a low index), or null if only loopback devices exist.
 */
export function pickMicDeviceIndex(devices: AudioDevice[]): string | null {
  const mic = devices.find((d) => !isLoopback(d.name));
  return mic ? mic.index : null;
}

/**
 * Resolve both device indices from the live ffmpeg device list. Returns the
 * detected index for each source (null when not found). Pure parsing lives in
 * the helpers above so they stay unit-testable without ffmpeg.
 */
export async function resolveAudioDevices(): Promise<{
  system: string | null;
  mic: string | null;
  devices: AudioDevice[];
}> {
  const listing = await listAudioDevices();
  const devices = parseAudioDevices(listing);
  return {
    system: pickSystemDeviceIndex(devices),
    mic: pickMicDeviceIndex(devices),
    devices,
  };
}
