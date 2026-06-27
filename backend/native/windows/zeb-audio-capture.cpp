// zeb Echo — Windows system-audio capture helper (WASAPI loopback).
//
// Captures the system audio output natively via WASAPI loopback on the default
// render endpoint (NO virtual device needed, unlike macOS BlackHole) and writes
// raw 16 kHz mono signed-16-bit-LE PCM to stdout, matching AUDIO_FORMAT
// (backend/src/protocol/messages.ts). The backend spawns this exactly like it
// spawns the macOS SCK helper / ffmpeg, so nothing downstream changes
// (PHASE2_PLAN.md §2b / M3).
//
// The endpoint's native mix format is usually 32-bit float at 44.1/48 kHz with
// 2 channels; we downmix to mono and linearly resample to 16 kHz, emitting s16.
//
// Build (MSVC): cl /O2 /EHsc zeb-audio-capture.cpp ole32.lib
// Exit codes: 0 normal, 3 setup/COM failure.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <io.h>
#include <fcntl.h>
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <vector>

// Target output format (must match AUDIO_FORMAT).
static const int kOutRate = 16000;
static const int kOutChannels = 1;

static void logmsg(const char* m) { fprintf(stderr, "[wasapi] %s\n", m); }

#define FAIL_IF(hr, msg) do { if (FAILED(hr)) { logmsg(msg); return 3; } } while (0)

int main() {
    // Binary stdout — never let the CRT translate \n to \r\n in the PCM stream.
    _setmode(_fileno(stdout), _O_BINARY);

    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    FAIL_IF(hr, "CoInitializeEx failed");

    IMMDeviceEnumerator* enumr = nullptr;
    hr = CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&enumr));
    FAIL_IF(hr, "create device enumerator failed");

    // Default render endpoint (what the user hears) — captured in loopback.
    IMMDevice* device = nullptr;
    hr = enumr->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    FAIL_IF(hr, "GetDefaultAudioEndpoint failed");

    IAudioClient* client = nullptr;
    hr = device->Activate(
        __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
        reinterpret_cast<void**>(&client));
    FAIL_IF(hr, "device->Activate failed");

    WAVEFORMATEX* mixFmt = nullptr;
    hr = client->GetMixFormat(&mixFmt);
    FAIL_IF(hr, "GetMixFormat failed");

    const int inRate = mixFmt->nSamplesPerSec;
    const int inChannels = mixFmt->nChannels;
    const int inBits = mixFmt->wBitsPerSample;
    // The mix format is typically IEEE float (WAVE_FORMAT_EXTENSIBLE wrapping
    // float). Detect float vs int so we read samples correctly.
    bool isFloat = false;
    if (mixFmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        isFloat = true;
    } else if (mixFmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        auto* ext = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mixFmt);
        isFloat = (ext->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    }

    // 200ms buffer; loopback must use a shared-mode stream.
    REFERENCE_TIME bufDur = 2000000; // 200ms in 100-ns units
    hr = client->Initialize(
        AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, bufDur, 0,
        mixFmt, nullptr);
    FAIL_IF(hr, "client->Initialize failed");

    IAudioCaptureClient* capture = nullptr;
    hr = client->GetService(
        __uuidof(IAudioCaptureClient), reinterpret_cast<void**>(&capture));
    FAIL_IF(hr, "GetService(capture) failed");

    hr = client->Start();
    FAIL_IF(hr, "client->Start failed");

    logmsg("capturing system audio (WASAPI loopback → 16kHz mono s16le → stdout)");

    // Resampler state: fractional read position into the incoming mono stream.
    double resamplePos = 0.0;
    const double step = static_cast<double>(inRate) / kOutRate;
    float prevSample = 0.0f; // last mono sample of the previous packet (for interp)

    std::vector<int16_t> outBuf;

    for (;;) {
        UINT32 packetLen = 0;
        hr = capture->GetNextPacketSize(&packetLen);
        if (FAILED(hr)) { logmsg("GetNextPacketSize failed"); break; }

        if (packetLen == 0) {
            Sleep(5); // no data yet; WASAPI loopback yields nothing during silence-free idle
            continue;
        }

        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        hr = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (FAILED(hr)) { logmsg("GetBuffer failed"); break; }

        // Downmix this packet to a mono float vector.
        std::vector<float> mono(frames);
        if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
            // Silent packet — emit zeros (keeps timing/resampler continuous).
            for (UINT32 i = 0; i < frames; ++i) mono[i] = 0.0f;
        } else if (isFloat && inBits == 32) {
            const float* f = reinterpret_cast<const float*>(data);
            for (UINT32 i = 0; i < frames; ++i) {
                double sum = 0.0;
                for (int c = 0; c < inChannels; ++c) sum += f[i * inChannels + c];
                mono[i] = static_cast<float>(sum / inChannels);
            }
        } else if (!isFloat && inBits == 16) {
            const int16_t* s = reinterpret_cast<const int16_t*>(data);
            for (UINT32 i = 0; i < frames; ++i) {
                int sum = 0;
                for (int c = 0; c < inChannels; ++c) sum += s[i * inChannels + c];
                mono[i] = (sum / inChannels) / 32768.0f;
            }
        } else {
            // Unsupported bit depth — release and skip.
            capture->ReleaseBuffer(frames);
            continue;
        }

        // Linear-resample the mono packet from inRate to kOutRate. We treat
        // prevSample as index -1 so interpolation is continuous across packets.
        // resamplePos is relative to the start of this packet.
        while (resamplePos < frames) {
            int idx = static_cast<int>(std::floor(resamplePos));
            double frac = resamplePos - idx;
            float a = (idx <= 0) ? prevSample : mono[idx - 1];
            float b = mono[idx];
            // Interpolate between sample idx-1 and idx.
            float v = static_cast<float>(a + (b - a) * frac);
            int s = static_cast<int>(std::lround(v * 32767.0f));
            if (s > 32767) s = 32767;
            if (s < -32768) s = -32768;
            outBuf.push_back(static_cast<int16_t>(s));
            resamplePos += step;
        }
        resamplePos -= frames; // carry fractional remainder into next packet
        prevSample = mono[frames - 1];

        capture->ReleaseBuffer(frames);

        if (!outBuf.empty()) {
            fwrite(outBuf.data(), sizeof(int16_t), outBuf.size(), stdout);
            fflush(stdout);
            outBuf.clear();
        }
    }

    client->Stop();
    CoUninitialize();
    return 0;
}
