// zeb Echo — macOS system-audio capture helper (ScreenCaptureKit).
//
// Captures the system audio output natively (NO BlackHole, NO Multi-Output
// device — speakers stay selected, volume keys keep working) and writes raw
// 16 kHz mono signed-16-bit-LE PCM to stdout, matching AUDIO_FORMAT
// (backend/src/protocol/messages.ts). The backend spawns this exactly like it
// spawned ffmpeg, so nothing downstream changes (PHASE2_PLAN.md §2a / M5).
//
// Requires macOS 13+ and the "Screen & System Audio Recording" permission.
// Exit codes: 0 normal, 2 unsupported OS, 3 permission/setup failure.
//
// Build: swiftc -O -framework ScreenCaptureKit -framework AVFoundation \
//          -o zeb-audio-capture zeb-audio-capture.swift

import AVFoundation
import ScreenCaptureKit

// Target output format (must match AUDIO_FORMAT).
let kSampleRate: Double = 16_000
let kChannels: AVAudioChannelCount = 1

// Log to stderr so stdout stays a pure PCM stream.
func log(_ msg: String) {
    FileHandle.standardError.write(("[sck] " + msg + "\n").data(using: .utf8)!)
}

@available(macOS 13.0, *)
final class AudioCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat?
    private let stdout = FileHandle.standardOutput

    func start() async throws {
        // Need a display to anchor an SCContentFilter; audio is captured for the
        // whole system regardless of which display we pick.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            log("no display available for capture filter")
            exit(3)
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true // don't capture our own output
        config.sampleRate = 48_000                 // SCK native; we downsample
        config.channelCount = 2
        // Keep the video path minimal — we only want audio, but a stream still
        // produces video frames; make them tiny + infrequent to waste nothing.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(
            self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "zeb.audio"))
        self.stream = stream
        try await stream.startCapture()
        log("capturing system audio (16kHz mono s16le → stdout)")
    }

    // Lazily build a converter from SCK's PCM format to our 16kHz mono s16le.
    private func makeConverter(from input: AVAudioFormat) {
        guard
            let out = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: kSampleRate,
                channels: kChannels, interleaved: true)
        else {
            log("failed to build output format")
            exit(3)
        }
        self.outFormat = out
        self.converter = AVAudioConverter(from: input, to: out)
        if self.converter == nil {
            log("failed to build audio converter")
            exit(3)
        }
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid,
            let pcm = sampleBuffer.toPCMBuffer()
        else { return }

        if converter == nil { makeConverter(from: pcm.format) }
        guard let converter, let outFormat else { return }

        // Output capacity scaled by the sample-rate ratio.
        let ratio = kSampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1024
        guard
            let outBuf = AVAudioPCMBuffer(
                pcmFormat: outFormat, frameCapacity: capacity)
        else { return }

        var fed = false
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, inStatus in
            if fed {
                inStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inStatus.pointee = .haveData
            return pcm
        }
        if status == .error {
            log("convert error: \(err?.localizedDescription ?? "unknown")")
            return
        }
        guard outBuf.frameLength > 0,
            let ch = outBuf.int16ChannelData
        else { return }

        let byteCount = Int(outBuf.frameLength) * MemoryLayout<Int16>.size
        stdout.write(Data(bytes: ch[0], count: byteCount))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped: \(error.localizedDescription)")
        exit(3)
    }
}

extension CMSampleBuffer {
    // Convert a CMSampleBuffer of audio into an AVAudioPCMBuffer.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(self),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)
        else { return nil }
        var streamDesc = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDesc) else {
            return nil
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

// --- entry point ---
guard #available(macOS 13.0, *) else {
    log("ScreenCaptureKit requires macOS 13+")
    exit(2)
}

let capturer = AudioCapturer()
Task {
    do {
        try await capturer.start()
    } catch {
        log("start failed: \(error.localizedDescription)")
        exit(3)
    }
}

// Run until killed (the backend manages our lifecycle via SIGTERM).
signal(SIGTERM, SIG_DFL)
RunLoop.main.run()
