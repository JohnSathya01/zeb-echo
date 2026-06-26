/**
 * Tests for avfoundation device parsing + name-based selection.
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  parseAudioDevices,
  pickMicDeviceIndex,
  pickSystemDeviceIndex,
} from './resolveDevices.js';

// Real-shape ffmpeg -list_devices output (audio section only matters).
const LISTING = `
[AVFoundation indev @ 0x12f] AVFoundation video devices:
[AVFoundation indev @ 0x12f] [0] FaceTime HD Camera
[AVFoundation indev @ 0x12f] AVFoundation audio devices:
[AVFoundation indev @ 0x12f] [0] BlackHole 2ch
[AVFoundation indev @ 0x12f] [1] MacBook Pro Microphone
[AVFoundation indev @ 0x12f] [2] Microsoft Teams Audio
`;

test('parses only the audio devices (not video) with index + name', () => {
  const devices = parseAudioDevices(LISTING);
  assert.deepEqual(devices, [
    { index: '0', name: 'BlackHole 2ch' },
    { index: '1', name: 'MacBook Pro Microphone' },
    { index: '2', name: 'Microsoft Teams Audio' },
  ]);
});

test('picks BlackHole as the system (loopback) device', () => {
  const devices = parseAudioDevices(LISTING);
  assert.equal(pickSystemDeviceIndex(devices), '0');
});

test('picks the first non-loopback input as the mic', () => {
  const devices = parseAudioDevices(LISTING);
  // index 0 is BlackHole (loopback) → mic should be index 1.
  assert.equal(pickMicDeviceIndex(devices), '1');
});

test('returns null for system when no loopback device is present', () => {
  const devices = parseAudioDevices(
    '[x] AVFoundation audio devices:\n[x] [0] MacBook Pro Microphone\n',
  );
  assert.equal(pickSystemDeviceIndex(devices), null);
  assert.equal(pickMicDeviceIndex(devices), '0');
});

test('handles an empty / deviceless listing', () => {
  assert.deepEqual(parseAudioDevices(''), []);
  assert.equal(pickSystemDeviceIndex([]), null);
  assert.equal(pickMicDeviceIndex([]), null);
});
