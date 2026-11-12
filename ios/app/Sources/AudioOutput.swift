//
//  AudioOutput.swift
//  3ds2apple
//
//  I3-T4: Zakuro audio (zk_take_audio) → AVAudioEngine.
//
//  Producer: the runtime serial queue drains interleaved stereo i16 samples
//  from the runtime and writes them into a fixed ring buffer.
//  Consumer: an AVAudioSourceNode render block (real-time thread) copies the
//  ring into float32 output buffers and silences the remainder on underrun.
//
//  The runtime is never blocked by audio: when the ring is full the oldest
//  audio is dropped, and when it is empty the render block outputs silence.
//

import AVFoundation
import AudioToolbox
import Foundation

/// UI-facing audio state.
enum AudioState {
    case off
    case running
    case muted
    case failed(String)

    var label: String {
        switch self {
        case .off: return "off"
        case .running: return "on"
        case .muted: return "muted"
        case .failed: return "failed"
        }
    }

    /// Failure detail for the UI, nil unless the engine failed to start.
    var failureMessage: String? {
        if case .failed(let message) = self {
            return message
        }
        return nil
    }
}

/// Fixed-capacity interleaved i16 ring buffer shared between the runtime queue
/// (writer) and the audio render callback (reader).
final class AudioRingBuffer {
    private let capacityFrames: Int
    private let channelCount: Int
    private let storage: UnsafeMutablePointer<Int16>
    private var readFrame = 0
    private var writeFrame = 0
    private var availableFrames = 0
    private var muted = false
    private var underrunFrames = 0
    private let lock = NSLock()

    init(capacityFrames: Int, channelCount: Int) {
        self.capacityFrames = max(capacityFrames, 1)
        self.channelCount = max(channelCount, 1)
        self.storage = UnsafeMutablePointer<Int16>.allocate(
            capacity: self.capacityFrames * self.channelCount
        )
        self.storage.initialize(repeating: 0, count: self.capacityFrames * self.channelCount)
    }

    deinit {
        storage.deinitialize(count: capacityFrames * channelCount)
        storage.deallocate()
    }

    // MARK: - Producer (runtime queue)

    /// Writes interleaved frames. Drops the oldest buffered audio when full so
    /// latency stays bounded; drops everything while muted. Never blocks on
    /// the audio thread beyond the tiny critical section.
    func write(_ source: UnsafePointer<Int16>, frameCount: Int) {
        guard frameCount > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !muted else { return }

        let incoming = min(frameCount, capacityFrames)
        let overflow = availableFrames + incoming - capacityFrames
        if overflow > 0 {
            readFrame = (readFrame + overflow) % capacityFrames
            availableFrames -= overflow
        }

        var written = 0
        while written < incoming {
            let contiguous = min(incoming - written, capacityFrames - writeFrame)
            storage.advanced(by: writeFrame * channelCount)
                .update(from: source.advanced(by: written * channelCount),
                        count: contiguous * channelCount)
            writeFrame = (writeFrame + contiguous) % capacityFrames
            written += contiguous
        }
        availableFrames += incoming
    }

    // MARK: - Consumer (audio render thread)

    /// Reads up to `frameCount` frames into separate left/right float buffers.
    /// Returns how many frames were copied; the caller silences the rest.
    func read(intoLeft left: UnsafeMutablePointer<Float>,
              right: UnsafeMutablePointer<Float>,
              frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        let count = min(frameCount, availableFrames)
        var read = 0
        while read < count {
            let contiguous = min(count - read, capacityFrames - readFrame)
            var pointer = storage.advanced(by: readFrame * channelCount)
            for offset in 0..<contiguous {
                left[read + offset] = Self.float(from: pointer[0])
                right[read + offset] = Self.float(from: pointer[1])
                pointer = pointer.advanced(by: channelCount)
            }
            readFrame = (readFrame + contiguous) % capacityFrames
            read += contiguous
        }
        availableFrames -= count
        if count < frameCount {
            underrunFrames += frameCount - count
        }
        return count
    }

    /// Mutes/unmutes and drops buffered audio (so unmuting never replays stale
    /// sound).
    func setMuted(_ muted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.muted = muted
        readFrame = 0
        writeFrame = 0
        availableFrames = 0
    }

    var isMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }

    var underruns: Int {
        lock.lock()
        defer { lock.unlock() }
        return underrunFrames
    }

    private static func float(from sample: Int16) -> Float {
        Float(sample) / 32768.0
    }
}

/// Owns the AVAudioEngine, the source node and the ring buffer.
///
/// Start/stop happen on the main thread; the render callback runs on the audio
/// thread and only touches the ring buffer (which is internally locked).
final class AudioOutput {
    /// Zakuro's `AUDIO_SAMPLE_RATE` (3DS DSP, `zakuro-core`). Declared on the
    /// source node and converted to the device rate by the engine's mixer; if
    /// Zakuro ever changes it, this is the one constant to update.
    static let sampleRate: Double = 32730
    static let channelCount: AVAudioChannelCount = 2
    /// One second of audio; enough to ride out frame-loop jitter.
    private static let capacityFrames = 32730

    private let ring = AudioRingBuffer(
        capacityFrames: AudioOutput.capacityFrames,
        channelCount: Int(AudioOutput.channelCount)
    )
    private let format: AVAudioFormat?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    init() {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        )
    }

    deinit {
        stopEngine()
    }

    /// Starts the audio session, engine and source node. Main thread.
    /// Returns false when the engine cannot start (the app keeps running).
    @discardableResult
    func startEngine() -> Bool {
        if engine != nil { return true }
        guard let format else {
            NSLog("[3ds2apple] audio: could not create a %.0f Hz stereo format", Self.sampleRate)
            return false
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch {
            NSLog("[3ds2apple] audio session failed: %@", error.localizedDescription)
            return false
        }

        let engine = AVAudioEngine()
        let node = Self.makeSourceNode(format: format, ring: ring)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("[3ds2apple] audio engine failed: %@", error.localizedDescription)
            engine.detach(node)
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
            return false
        }

        self.engine = engine
        self.sourceNode = node
        NSLog("[3ds2apple] audio started: %.0f Hz stereo i16 → AVAudioEngine", Self.sampleRate)
        return true
    }

    /// Stops the engine and releases buffered audio. Main thread.
    func stopEngine() {
        guard let engine else { return }
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
        }
        self.engine = nil
        self.sourceNode = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        ring.setMuted(false)
        NSLog("[3ds2apple] audio stopped")
    }

    /// runtimeQueue: push one frame batch of interleaved i16 samples.
    func enqueue(_ samples: UnsafePointer<Int16>, frameCount: Int) {
        ring.write(samples, frameCount: frameCount)
    }

    func setMuted(_ muted: Bool) {
        ring.setMuted(muted)
    }

    var isMuted: Bool { ring.isMuted }
    var underrunFrames: Int { ring.underruns }

    private static func makeSourceNode(format: AVAudioFormat,
                                       ring: AudioRingBuffer) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) {
            isSilence, _, frameCount, audioBufferList -> OSStatus in
            let requested = Int(frameCount)
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard requested > 0,
                  buffers.count >= 2,
                  let leftRaw = buffers[0].mData,
                  let rightRaw = buffers[1].mData else {
                isSilence.pointee = true
                return noErr
            }

            let left = leftRaw.assumingMemoryBound(to: Float.self)
            let right = rightRaw.assumingMemoryBound(to: Float.self)
            let read = ring.read(intoLeft: left, right: right, frameCount: requested)
            if read < requested {
                // Underrun (emulation slower than real time): pad with silence
                // instead of blocking the runtime.
                for index in read..<requested {
                    left[index] = 0
                    right[index] = 0
                }
            }
            if read == 0 {
                isSilence.pointee = true
            }
            return noErr
        }
    }
}
