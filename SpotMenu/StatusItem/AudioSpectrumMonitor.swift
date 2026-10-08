import Accelerate
import AppKit
import Combine
import CoreAudio

/// Listens to the sound coming out of Spotify / Apple Music (only those apps)
/// using a Core Audio process tap (audio only, no screen access), runs an FFT,
/// and publishes two sets of levels (0...1):
///   - `bassLevels`: 30-160 Hz, for the bass bars
///   - `restLevels`: 160 Hz-12 kHz, for the other bars
///
/// Capture only runs while music is playing; it stops a couple of seconds
/// after playback pauses so macOS's recording indicator goes away.
final class AudioSpectrumMonitor: ObservableObject {
    static let shared = AudioSpectrumMonitor()

    static let bassBandCount = 4
    static let restBandCount = 8

    @Published private(set) var bassLevels: [Float] = Array(repeating: 0, count: bassBandCount)
    @Published private(set) var restLevels: [Float] = Array(repeating: 0, count: restBandCount)
    /// True once real (non-silent) sound is arriving.
    @Published private(set) var isReceiving = false
    /// True while the audio tap is set up and running.
    @Published private(set) var tapRunning = false
    /// Last setup error, for the status line in Preferences.
    @Published private(set) var lastError: String?

    private var isStarting = false
    private var lastStartAttempt = Date.distantPast
    private var pendingStop: DispatchWorkItem?
    private var lastSoundDate = Date.distantPast
    private var lastPublish = Date.distantPast
    private var lastAnalysis = Date.distantPast
    private var silenceTimer: Timer?

    // Core Audio objects
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var channelCount = 2
    private var isInterleaved = true

    private let audioQueue = DispatchQueue(label: "SpotMenu.AudioSpectrum", qos: .userInteractive)

    // FFT state (only touched on audioQueue)
    // 4096 samples at 48 kHz = ~12 Hz per bin: enough detail to split the bass.
    private let fftSize = 4096
    private let log2n = vDSP_Length(12)
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var sampleRing: [Float]
    private var sampleRate: Double = 48_000
    private var bassSmoothed = [Float](repeating: 0, count: bassBandCount)
    private var restSmoothed = [Float](repeating: 0, count: restBandCount)
    private var bassPeakDb: Float = -30
    private var restPeakDb: Float = -30

    private init() {
        window = [Float](repeating: 0, count: 4096)
        sampleRing = [Float](repeating: 0, count: 4096)
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
            if !tapRunning, !isStarting,
                Date().timeIntervalSince(lastStartAttempt) > 6
            {
                start()
            }
        } else if tapRunning, pendingStop == nil {
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            pendingStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
    }

    /// Lets the user retry right away (e.g. after changing permissions).
    func resetPermissionState() {
        lastError = nil
        lastStartAttempt = .distantPast
    }

    private func start() {
        guard #available(macOS 14.4, *) else {
            lastError = "Needs macOS 14.4 or newer."
            return
        }
        isStarting = true
        lastStartAttempt = Date()
        defer { isStarting = false }

        do {
            try startTap()
            tapRunning = true
            lastError = nil
            startSilenceWatch()
        } catch let error as TapError {
            teardown()
            if error.message == TapError.noMusicApp.message {
                lastError = nil  // music app hasn't played yet; retry later
            } else {
                lastError = error.message
            }
        } catch {
            teardown()
            lastError = error.localizedDescription
        }
    }

    private func stop() {
        pendingStop = nil
        teardown()
        isReceiving = false
        bassLevels = Array(repeating: 0, count: Self.bassBandCount)
        restLevels = Array(repeating: 0, count: Self.restBandCount)
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.bassSmoothed = Array(repeating: 0, count: Self.bassBandCount)
            self.restSmoothed = Array(repeating: 0, count: Self.restBandCount)
            self.sampleRing = [Float](repeating: 0, count: self.fftSize)
        }
    }

    /// Falls back to the simulated animation if no sound arrives for a while.
    private func startSilenceWatch() {
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isReceiving, Date().timeIntervalSince(self.lastSoundDate) > 8 {
                self.isReceiving = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    // MARK: - Core Audio tap

    private struct TapError: Error {
        let message: String
        static let noMusicApp = TapError(message: "no music app")
        static func failed(_ what: String, _ status: OSStatus) -> TapError {
            TapError(message: "\(what) failed (\(status))")
        }
    }

    @available(macOS 14.4, *)
    private func startTap() throws {
        // 1) Find the audio "process objects" of Spotify / Music.
        let processes = musicProcessObjects()
        guard !processes.isEmpty else { throw TapError.noMusicApp }

        // 2) Create a private tap that mixes their output to stereo.
        //    .unmuted = you still hear the music normally.
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "SpotMenu Equalizer"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else { throw TapError.failed("Creating the audio tap", status) }
        tapID = newTap

        // 3) Read the tap's audio format.
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw TapError.failed("Reading the tap format", status) }
        let rate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        channelCount = max(1, Int(format.mChannelsPerFrame))
        isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        audioQueue.sync { self.sampleRate = rate }

        // 4) Wrap the tap in a private aggregate device so we can read from it.
        guard let outputUID = defaultOutputDeviceUID() else {
            throw TapError(message: "No audio output device found")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpotMenu Equalizer Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard status == noErr else { throw TapError.failed("Creating the audio device", status) }
        aggregateID = newAggregate

        // 5) Receive the audio. The first time, macOS asks for
        //    "System Audio Recording Only" permission.
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, audioQueue) {
            [weak self] _, inputData, _, _, _ in
            self?.handleInput(inputData)
        }
        guard status == noErr, let procID else {
            throw TapError.failed("Setting up audio input", status)
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError.failed("Starting audio", status) }
    }

    private func teardown() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapRunning = false
    }

    /// Audio process objects belonging to Spotify or Apple Music (including
    /// helper processes such as Spotify's).
    @available(macOS 14.2, *)
    private func musicProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }

        var objects = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr
        else { return [] }

        return objects.filter { object in
            guard let bundleID = processBundleID(object) else { return false }
            return bundleID.hasPrefix("com.spotify.") || bundleID == "com.apple.Music"
        }
    }

    @available(macOS 14.2, *)
    private func processBundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString? = nil
        size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uid else { return nil }
        return uid as String
    }

    // MARK: - Analysis (audioQueue)

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard total > 0 else { return }

        // Use the left channel (or the only channel).
        let stride = (isInterleaved && channelCount > 1) ? channelCount : 1
        let frames = total / stride
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames { mono[i] = floats[i * stride] }

        if frames >= fftSize {
            sampleRing = Array(mono.suffix(fftSize))
        } else {
            sampleRing.removeFirst(frames)
            sampleRing.append(contentsOf: mono)
        }

        // ~60 analyses per second is plenty for the menu bar.
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= 1.0 / 60.0 else { return }
        lastAnalysis = now
        analyze(now: now)
    }

    private func analyze(now: Date) {
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
        func bandDb(_ lowHz: Float, _ highHz: Float) -> Float {
            var i0 = Int(lowHz / binHz)
            var i1 = Int(highHz / binHz)
            i0 = max(1, min(i0, half - 1))
            i1 = max(i0 + 1, min(i1, half))
            var sum: Float = 0
            for i in i0..<i1 { sum += mags[i] }
            return 10 * log10f(sum / Float(i1 - i0) + 1e-12)
        }
        func logBands(_ count: Int, _ lowHz: Float, _ highHz: Float, tilt: Float) -> [Float] {
            (0..<count).map { b in
                let f0 = lowHz * powf(highHz / lowHz, Float(b) / Float(count))
                let f1 = lowHz * powf(highHz / lowHz, Float(b + 1) / Float(count))
                return bandDb(f0, f1) + Float(b) * tilt
            }
        }

        // Bass bars: 30-160 Hz. Tight range + snappy motion so kicks pop.
        let bassDb = logBands(Self.bassBandCount, 30, 160, tilt: 0)
        // Other bars: 160 Hz-12 kHz, with a gentle tilt so treble isn't tiny.
        let restDb = logBands(Self.restBandCount, 160, 12_000, tilt: 2.0)

        let loudest = max(bassDb.max() ?? -140, restDb.max() ?? -140)
        let silent = loudest < -75

        bassPeakDb = max(bassDb.max() ?? -140, bassPeakDb - 0.12)
        restPeakDb = max(restDb.max() ?? -140, restPeakDb - 0.15)

        for b in 0..<Self.bassBandCount {
            let range: Float = 22
            let target: Float = silent
                ? 0 : max(0, min(1, (bassDb[b] - (bassPeakDb - range)) / range))
            let k: Float = target > bassSmoothed[b] ? 0.85 : 0.3
            bassSmoothed[b] += (target - bassSmoothed[b]) * k
        }
        for b in 0..<Self.restBandCount {
            let range: Float = 40
            let target: Float = silent
                ? 0 : max(0, min(1, (restDb[b] - (restPeakDb - range)) / range))
            let k: Float = target > restSmoothed[b] ? 0.65 : 0.18
            restSmoothed[b] += (target - restSmoothed[b]) * k
        }

        guard now.timeIntervalSince(lastPublish) >= 1.0 / 30.0 else { return }
        lastPublish = now
        let bass = bassSmoothed
        let rest = restSmoothed
        let heardSound = !silent
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if heardSound {
                self.lastSoundDate = now
                if !self.isReceiving { self.isReceiving = true }
            }
            self.bassLevels = bass
            self.restLevels = rest
        }
    }
}
