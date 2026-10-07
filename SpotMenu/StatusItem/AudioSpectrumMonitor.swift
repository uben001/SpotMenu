import Accelerate
import AppKit
import Combine
import CoreMedia
import ScreenCaptureKit

/// Listens to the audio coming out of Spotify / Apple Music (only those apps)
/// using ScreenCaptureKit, runs an FFT, and publishes band levels (0...1)
/// that the menu bar equalizer draws.
///
/// Capture only runs while music is playing; it stops a couple of seconds
/// after playback pauses so macOS's recording indicator goes away.
final class AudioSpectrumMonitor: NSObject, ObservableObject, SCStreamOutput,
    SCStreamDelegate
{
    static let shared = AudioSpectrumMonitor()

    static let bandCount = 10
    static let musicApps: Set<String> = ["com.spotify.client", "com.apple.Music"]

    /// Smoothed level per band, 0...1.
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: bandCount)
    /// True while real audio data is arriving.
    @Published private(set) var isReceiving = false
    /// True if macOS refused screen & system audio recording permission.
    @Published private(set) var permissionDenied = false

    private var stream: SCStream?
    private var isStarting = false
    private var lastStartAttempt = Date.distantPast
    private var pendingStop: DispatchWorkItem?
    private var lastSampleDate = Date.distantPast
    private var lastPublish = Date.distantPast
    private var silenceTimer: Timer?

    private let audioQueue = DispatchQueue(label: "SpotMenu.AudioSpectrum")

    // FFT state (only touched on audioQueue)
    private let fftSize = 1024
    private let log2n = vDSP_Length(10)
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var sampleRing: [Float]
    private var smoothed: [Float] = Array(repeating: 0, count: bandCount)
    private var peakDb: Float = -30
    private var sampleRate: Double = 48_000

    private override init() {
        window = [Float](repeating: 0, count: 1024)
        sampleRing = [Float](repeating: 0, count: 1024)
        super.init()
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    // MARK: - Control

    /// Call regularly (e.g. every second) with whether capture should run.
    func update(shouldRun: Bool) {
        if shouldRun {
            pendingStop?.cancel()
            pendingStop = nil
            if stream == nil, !isStarting, !permissionDenied,
                Date().timeIntervalSince(lastStartAttempt) > 8
            {
                start()
            }
        } else if stream != nil, pendingStop == nil {
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            pendingStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
    }

    /// Lets the user retry after granting permission in System Settings.
    func resetPermissionState() {
        permissionDenied = false
        lastStartAttempt = .distantPast
    }

    private func start() {
        isStarting = true
        lastStartAttempt = Date()

        Task { @MainActor in
            defer { self.isStarting = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                let apps = content.applications.filter {
                    Self.musicApps.contains($0.bundleIdentifier)
                }
                guard let display = content.displays.first, !apps.isEmpty else {
                    return  // music app not running yet; retry later
                }

                let filter = SCContentFilter(
                    display: display,
                    including: apps,
                    exceptingWindows: []
                )
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                // We only want audio; keep the video side as tiny as possible.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.showsCursor = false

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
                try await stream.startCapture()
                self.stream = stream
                self.sampleRate = Double(config.sampleRate)
                self.startSilenceWatch()
            } catch {
                // SCStreamError.userDeclined (-3801): no screen & audio recording permission.
                if (error as NSError).code == SCStreamError.Code.userDeclined.rawValue {
                    self.permissionDenied = true
                }
                NSLog("SpotMenu audio capture failed: \(error)")
            }
        }
    }

    private func stop() {
        pendingStop = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
        isReceiving = false
        levels = Array(repeating: 0, count: Self.bandCount)
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.smoothed = Array(repeating: 0, count: Self.bandCount)
            self.sampleRing = [Float](repeating: 0, count: self.fftSize)
        }
    }

    /// Marks the feed as not receiving if no audio arrived for a while.
    private func startSilenceWatch() {
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isReceiving, Date().timeIntervalSince(self.lastSampleDate) > 1.0 {
                self.isReceiving = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.isReceiving = false
            self.levels = Array(repeating: 0, count: Self.bandCount)
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }

        try? sampleBuffer.withAudioBufferList { bufferList, _ in
            guard let buffer = bufferList.first, let data = buffer.mData else { return }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return }
            let samples = UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self),
                count: count
            )
            self.push(samples)
        }
    }

    // MARK: - Analysis (audioQueue)

    private func push(_ samples: UnsafeBufferPointer<Float>) {
        // Slide the newest samples into the analysis window.
        if samples.count >= fftSize {
            sampleRing = Array(samples.suffix(fftSize))
        } else {
            sampleRing.removeFirst(samples.count)
            sampleRing.append(contentsOf: samples)
        }
        analyze()
    }

    private func analyze() {
        guard let fftSetup else { return }
        let n = fftSize
        let half = n / 2

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(sampleRing, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )
                windowed.withUnsafeBufferPointer { wPtr in
                    wPtr.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: half
                    ) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        // Group bins into log-spaced bands from ~50 Hz to ~14 kHz.
        let binHz = Float(sampleRate) / Float(n)
        let lowHz: Float = 50
        let highHz: Float = 14_000
        let bands = Self.bandCount
        var bandDb = [Float](repeating: -140, count: bands)

        for b in 0..<bands {
            let f0 = lowHz * powf(highHz / lowHz, Float(b) / Float(bands))
            let f1 = lowHz * powf(highHz / lowHz, Float(b + 1) / Float(bands))
            var i0 = Int(f0 / binHz)
            var i1 = Int(f1 / binHz)
            i0 = max(1, min(i0, half - 1))
            i1 = max(i0 + 1, min(i1, half))
            var sum: Float = 0
            for i in i0..<i1 { sum += mags[i] }
            let avg = sum / Float(i1 - i0)
            // Gentle tilt so treble bands aren't always tiny.
            bandDb[b] = 10 * log10f(avg + 1e-12) + Float(b) * 2.0
        }

        let loudest = bandDb.max() ?? -140
        let silent = loudest < -70

        // Adaptive range: follow the loudest band, decay slowly.
        peakDb = max(loudest, peakDb - 0.15)
        let range: Float = 42
        let floorDb = peakDb - range

        for b in 0..<bands {
            let target: Float = silent ? 0 : max(0, min(1, (bandDb[b] - floorDb) / range))
            let current = smoothed[b]
            // Fast attack, slower release, like a real VU meter.
            let k: Float = target > current ? 0.65 : 0.18
            smoothed[b] = current + (target - current) * k
        }

        let now = Date()
        guard now.timeIntervalSince(lastPublish) >= 1.0 / 30.0 else { return }
        lastPublish = now
        let snapshot = smoothed
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastSampleDate = now
            self.levels = snapshot
            if !self.isReceiving { self.isReceiving = true }
        }
    }
}
