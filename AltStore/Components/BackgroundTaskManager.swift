//
//  BackgroundTaskManager.swift
//  AltStore
//
//  Created by Riley Testut on 6/19/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import AVFoundation
import Foundation

/// Keeps the app alive in the background by looping a silent WAV.
///
/// This mirrors the keep-alive that SideStore already ships in
/// `BackgroundAudioService`, which is the implementation known to survive a
/// locked screen:
///
/// * the WAV is generated in code, so no bundle resource is involved (LiveContainer
///   loads SideStore as a dylib and `Bundle.main` points at the host app);
/// * `AVAudioPlayer` with `numberOfLoops = -1` and a small non-zero `volume`,
///   because a zero volume can look like "not rendering audio" to the system;
/// * an interruption observer that resumes playback when iOS ends the interruption;
/// * `isRunning` is `player?.isPlaying`, so callers always see the real state.
///
/// Unlike `BackgroundAudioService`, nothing here switches the user's background
/// service mode or touches the location service.
final class BackgroundTaskManager: @unchecked Sendable
{
    static let shared = BackgroundTaskManager()

    private let queue = DispatchQueue(label: "com.altstore.BackgroundTaskManager")

    private var player: AVAudioPlayer?
    private var interruptionObserver: (any NSObjectProtocol)?

    private init()
    {
        self.interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
    }

    deinit
    {
        if let interruptionObserver = self.interruptionObserver
        {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        self.player?.stop()
    }

    /// Whether the silent loop is actually playing. Thread safe.
    var isRunning: Bool
    {
        queue.sync { self.player?.isPlaying == true }
    }
}

extension BackgroundTaskManager
{
    /// Starts the silent loop. Returns immediately when it already plays.
    func start() throws
    {
        try queue.sync {
            guard self.player?.isPlaying != true else { return }
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

    /// Stops the loop. Safe to call repeatedly.
    func stop()
    {
        queue.sync {
            guard self.player != nil else { return }

            self.player?.stop()
            self.player = nil

            // The audio session is process-wide. Deactivating it while the
            // optional BackgroundAudioService keep-alive is playing would silently
            // disable that feature, so hand the session over instead.
            if !BackgroundAudioService.shared.isRunning
            {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
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
    /// Builds the player and starts playback. The caller must already hold `queue`.
    func startWhileLocked() throws
    {
        // LiveContainer and SideStore share one process, and the app-wide
        // background service may already be looping its own silent WAV. Stop it so
        // a single keep-alive owns the session and the reported state stays
        // truthful. Stopping it has no other side effect: unlike `start()`, its
        // `stop()` does not switch the background service mode.
        if BackgroundAudioService.shared.isRunning
        {
            BackgroundAudioService.shared.stop()
            debugLog("Stopped BackgroundAudioService before taking over the audio session.")
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)

        // A player that went through an interruption may refuse to resume, so
        // build a fresh one whenever playback is not actually running.
        if self.player?.isPlaying != true
        {
            self.player?.stop()
            self.player = nil

            do
            {
                let player = try AVAudioPlayer(data: BackgroundAudioService.generateSilentWAV())
                player.numberOfLoops = -1
                player.volume = 0.01
                _ = player.prepareToPlay()
                self.player = player
            }
            catch
            {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                throw error
            }
        }

        guard self.player?.play() == true else
        {
            self.player = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw BackgroundTaskManagerError.playbackFailed
        }

        debugLog("Silent-audio background task started.")
    }

    /// Resumes playback after iOS ends an interruption.
    func handleInterruption(_ notification: Notification)
    {
        guard
            let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue),
            type == .ended
        else
        {
            return
        }

        queue.sync {
            guard let player = self.player else { return }
            do
            {
                try AVAudioSession.sharedInstance().setActive(true)
                _ = player.play()
                debugLog("Silent-audio background task resumed after an interruption.")
            }
            catch
            {
                debugLog("Could not resume the silent-audio background task. \(error)")
            }
        }
    }
}

enum BackgroundTaskManagerError: LocalizedError
{
    case playbackFailed

    var errorDescription: String?
    {
        switch self
        {
        case .playbackFailed:
            return "Could not start silent audio playback"
        }
    }
}
