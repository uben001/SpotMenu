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
    /// Last capture error, for the status line in Preferences.
    @Published private(set) var lastError: String?

    private var stream: SCStream?
    private var isStarting = false
    private var lastStartAttempt = Date.distantPast
    private var pendingStop: DispatchWorkItem?
    private var lastSampleDate = Date.distantPast
    private var lastPublish = Date.distantPast
    private var silenceTimer: Timer?

    private let audioQueue = DispatchQueue(label: "SpotMenu.AudioSpectrum")

    // FFT state (only touched on audioQueue)
    // 2048 samples at 48 kHz = ~23 Hz per bin: enough detail to separate
    // kick drum / bass from the rest.
    private let fftSize = 2048
    private let log2n = vDSP_Length(11)
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var sampleRing: [Float]
    private var smoothed: [Float] = Array(repeating: 0, count: bandCount)
    private var peakDb: Float = -30
    private var bassPeakDb: Float = -30
    private var bassLevel: Float = 0
    private var sampleRate: Double = 48_000

    private override init() {
        window = [Float](repeating: 0, count: 2048)
        sampleRing = [Float](repeating: 0, count: 2048)
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
        lastError = nil
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
                self.lastError = nil
                self.sampleRate = Double(config.sampleRate)
                self.startSilenceWatch()
            } catch {
                // SCStreamError.userDeclined (-3801): no screen & audio recording permission.
                if (error as NSError).code == SCStreamError.Code.userDeclined.rawValue {
                    self.permissionDenied = true
                }
                self.lastError = error.localizedDescription
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
            self.bassLevel = 0
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

        let binHz = Float(sampleRate) / Float(n)
        func energy(_ lowHz: Float, _ highHz: Float) -> Float {
            var i0 = Int(lowHz / binHz)
            var i1 = Int(highHz / binHz)
            i0 = max(1, min(i0, half - 1))
            i1 = max(i0 + 1, min(i1, half))
            var sum: Float = 0
            for i in i0..<i1 { sum += mags[i] }
            return sum / Float(i1 - i0)
        }

        // 1) Bass / kick envelope (40-160 Hz). This is what the bars mainly
        //    follow, so every kick drum and bass note makes them jump.
        let bassDb = 10 * log10f(energy(40, 160) + 1e-12)
        bassPeakDb = max(bassDb, bassPeakDb - 0.12)
        let bassRange: Float = 20
        let bassTarget: Float = max(0, min(1, (bassDb - (bassPeakDb - bassRange)) / bassRange))
        // Snappy: jump up instantly on a hit, fall back quickly between hits.
        let bassK: Float = bassTarget > bassLevel ? 0.85 : 0.30
        bassLevel += (bassTarget - bassLevel) * bassK

        // 2) Spectrum bands, log-spaced from 30 Hz to 8 kHz (most bars sit in
        //    the low end), used for a bit of variety between bars.
        let lowHz: Float = 30
        let highHz: Float = 8_000
        let bands = Self.bandCount
        var bandDb = [Float](repeating: -140, count: bands)
        for b in 0..<bands {
            let f0 = lowHz * powf(highHz / lowHz, Float(b) / Float(bands))
            let f1 = lowHz * powf(highHz / lowHz, Float(b + 1) / Float(bands))
            bandDb[b] = 10 * log10f(energy(f0, f1) + 1e-12)
        }

        let loudest = max(bandDb.max() ?? -140, bassDb)
        let silent = loudest < -70
        if silent { bassLevel = 0 }

        peakDb = max(bandDb.max() ?? -140, peakDb - 0.15)
        let range: Float = 36
        let floorDb = peakDb - range

        for b in 0..<bands {
            let bandLevel: Float = max(0, min(1, (bandDb[b] - floorDb) / range))
            // Bass drives every bar (strongest on the left/low bars);
            // the band's own level adds some movement on top.
            let bassWeight: Float = 1.0 - 0.35 * Float(b) / Float(bands - 1)
            let mixed = 0.65 * bassLevel * bassWeight + 0.35 * bandLevel
            let target: Float = silent ? 0 : max(0, min(1, mixed))
            let current = smoothed[b]
            // Fast attack, quick release so the beat reads clearly.
            let k: Float = target > current ? 0.8 : 0.28
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
