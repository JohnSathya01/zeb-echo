/**
 * CLI helper: print avfoundation audio input devices so the user can find the
 * BlackHole device index for AUDIO_DEVICE_INDEX. Run via `npm run devices`.
 */
import { listAudioDevices } from './SystemAudioCapture.js';

const listing = await listAudioDevices();
console.log(listing || 'No device listing returned (is ffmpeg installed?).');
