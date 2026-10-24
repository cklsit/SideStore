//
//  BackgroundTaskManager.swift
//  AltStore
//
//  Created by Riley Testut on 6/19/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import AVFoundation
import Foundation

/// Keeps the app alive in the background by looping a silent audio buffer.
///
/// The previous implementation streamed `Bundle.main/Silence.m4a`. LiveContainer
/// loads SideStore as a dylib, so `Bundle.main` points at the host app and that
/// resource lookup is not dependable. The buffer is therefore generated in code
/// instead, and playback can be started, stopped and re-checked repeatedly so the
/// deployment endpoint can pull the keep-alive back up after iOS interrupts it.
final class BackgroundTaskManager: @unchecked Sendable
{
    static let shared = BackgroundTaskManager()

    /// Length of the looped silent buffer in seconds.
    private static let bufferDuration: Double = 1.0
    private static let sampleRate: Double = 44100

    private let queue = DispatchQueue(label: "com.altstore.BackgroundTaskManager")

    // Every access below happens on `queue`; `isRunning` reads it synchronously.
    private var running = false
    private var sessionIsActive = false
    private var audioEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var silentBuffer: AVAudioPCMBuffer?

    private init() {}

    /// Whether the silent-audio loop is currently playing. Thread safe.
    var isRunning: Bool {
        queue.sync { self.running }
    }
}

extension BackgroundTaskManager
{
    /// Starts the silent-audio loop. Returns immediately when it already runs.
    func start() throws
    {
        try queue.sync {
            guard !self.running else { return }
            try self.startWhileLocked()
        }
    }

    /// Starts the loop when needed, logging instead of throwing.
    ///
    /// The deployment endpoint calls this on every request, so a loop that iOS
    /// interrupted is picked up again by the runner's two-second polling.
    func ensureRunning()
    {
        guard !self.isRunning else { return }
        do
        {
            try self.start()
        }
        catch
        {
            debugLog("Could not start the silent-audio background task. \(error)")
        }
    }

    /// Stops the loop and deactivates the audio session. Safe to call repeatedly.
    func stop()
    {
        queue.sync {
            self.stopWhileLocked()
        }
    }

    /// Legacy entry point used by the background fetch in AppDelegate.
    ///
    /// The manager is shared with the deployment endpoint, so the failure path
    /// deliberately leaves playback alone: nothing was started here, and stopping
    /// would cut a keep-alive that the endpoint owns.
    func performExtendedBackgroundTask(taskHandler: @escaping ((Result<Void, Error>, @escaping () -> Void) -> Void))
    {
        do
        {
            try self.start()
            taskHandler(.success(())) { [weak self] in
                self?.stop()
            }
        }
        catch
        {
            taskHandler(.failure(error)) { }
        }
    }
}

private extension BackgroundTaskManager
{
    /// Builds and starts the engine. The caller must already hold `queue`.
    func startWhileLocked() throws
    {
        let session = AVAudioSession.sharedInstance()
        do
        {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        }
        catch
        {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        self.sessionIsActive = true

        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.sampleRate * Self.bufferDuration))
        else
        {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            self.sessionIsActive = false
            throw BackgroundTaskManagerError.bufferUnavailable
        }

        buffer.frameLength = buffer.frameCapacity
        // AVAudioPCMBuffer memory is not guaranteed to be zeroed, so fill the
        // frames explicitly. This is what keeps the loop actually silent.
        if let channels = buffer.floatChannelData
        {
            let frameCount = Int(buffer.frameLength)
            let byteCount = frameCount * MemoryLayout<Float>.size
            for channel in 0..<Int(buffer.format.channelCount)
            {
                memset(channels[channel], 0, byteCount)
            }
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // The mixer volume stays at its default: the buffer is already all zeros,
        // so the output is silent anyway, while a zero mixer volume could make the
        // engine (or the system) treat the session as "not rendering audio" and
        // weaken the very keep-alive this class exists for.

        do
        {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
        }
        catch
        {
            player.stop()
            engine.stop()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            self.sessionIsActive = false
            throw error
        }

        self.audioEngine = engine
        self.player = player
        self.silentBuffer = buffer
        self.running = true

        debugLog("Silent-audio background task started.")
    }

    /// Tears the engine down. The caller must already hold `queue`.
    func stopWhileLocked()
    {
        guard self.running || self.audioEngine != nil || self.sessionIsActive else { return }

        self.player?.stop()
        self.audioEngine?.stop()

        // The audio session is process-wide. Deactivating it while the optional
        // BackgroundAudioService keep-alive is playing would silently disable
        // that feature, so hand the session over instead of tearing it down.
        if self.sessionIsActive && !BackgroundAudioService.shared.isRunning
        {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        self.sessionIsActive = false

        self.player = nil
        self.audioEngine = nil
        self.silentBuffer = nil
        self.running = false

        debugLog("Silent-audio background task stopped.")
    }
}

enum BackgroundTaskManagerError: LocalizedError
{
    case bufferUnavailable

    var errorDescription: String?
    {
        switch self
        {
        case .bufferUnavailable:
            return "Could not allocate the silent audio buffer"
        }
    }
}
