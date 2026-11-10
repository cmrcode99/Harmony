import Cocoa
import WebKit

/// Bridges the local player state and native playback controls.
extension App {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "togglePlayback", message.frameInfo.isMainFrame,
              let state = message.body as? [String: Any],
              let paused = state["paused"] as? Bool,
              let revision = state["revision"] as? Int,
              let generation = state["generation"] as? Int,
              generation == playerGeneration, revision > playbackRevision else { return }
        playbackPaused = paused
        playbackRevision = revision
        if let index = state["index"] as? Int, (0..<1024).contains(index) {
            playlistIndex = index
            pendingSeek = nil
            playbackSlider.isEnabled = false
            playbackSlider.doubleValue = 0
        }
        updatePlayer()
    }
    /// State changes are coalesced; idle playback needs no repeated JS writes.
    func updatePlayer() {
        playerStateDirty = true
        flushPlayerState()
    }
    private func flushPlayerState() {
        guard playerReady, (playerStateDirty || pendingSeek != nil || pendingSkips > 0), !playerJavaScriptInFlight else { return }
        playerStateDirty = false
        let seekPosition = pendingSeek
        pendingSeek = nil
        let skips = pendingSkips
        pendingSkips = 0
        playerJavaScriptInFlight = true
        let generation = playerGeneration
        let js = """
        (() => {
          const v=document.querySelector('video');
          if(!v) return null;
          const targetVolume=\(volume / 100);
          const targetMuted=\((muted || !panel.isVisible) ? "true" : "false");
          if(v.volume!==targetVolume) v.volume=targetVolume;
          if(v.defaultMuted!==targetMuted) v.defaultMuted=targetMuted;
          if(v.muted!==targetMuted) v.muted=targetMuted;
          if(window.harmonyApplyPlayback) window.harmonyApplyPlayback(\(playbackPaused ? "true" : "false"), \(playbackRevision), \(panel.isVisible ? "true" : "false"), \(generation), \(playlistIndex));
          \(skips > 0 ? "if(window.harmonySkipVideo) window.harmonySkipVideo(\(skips));" : "")
          \(seekPosition.map { "if(window.harmonySeekPlayback) window.harmonySeekPlayback(\($0.position),\($0.track));" } ?? "")
          return window.harmonyPlaybackSnapshot ? window.harmonyPlaybackSnapshot() : null;
        })();
        """
        web.evaluateJavaScript(js) { [weak self] value, _ in
            self?.finishPlayerJavaScript(value, generation: generation)
        }
    }
    func pollPlaybackPosition() {
        guard playerReady, panel.isVisible, playerContainer?.controlsVisible == true,
              !playerJavaScriptInFlight else { return }
        playerJavaScriptInFlight = true
        let generation = playerGeneration
        web.evaluateJavaScript("window.harmonyPlaybackSnapshot ? window.harmonyPlaybackSnapshot() : null") { [weak self] value, _ in
            self?.finishPlayerJavaScript(value, generation: generation)
        }
    }
    func finishPlayerJavaScript(_ value: Any?, generation: Int) {
        guard generation == playerGeneration else { return }
        playerJavaScriptInFlight = false
        if panel.isVisible, playerContainer?.controlsVisible == true {
            applyPlaybackSnapshot(value)
        }
        flushPlayerState()
    }

    /// Apply only a settled snapshot. A missing timeline means the current
    /// media cannot be played, so previously enabled seeking must be cleared.
    func applyPlaybackSnapshot(_ value: Any?, isDragging: Bool = NSEvent.pressedMouseButtons != 0) {
        guard pendingSeek == nil, pendingSkips == 0 else { return }
        guard let times = value as? [Double], times.count == 4 else {
            clearPlaybackTimeline()
            return
        }
        // User input may have superseded this result while WebKit was working.
        guard times[2] == Double(playlistIndex), times[3] == Double(playbackRevision) else { return }
        guard times[0].isFinite, times[1].isFinite, times[0] >= 0,
              times[1] > 0, times[0] <= times[1] else {
            clearPlaybackTimeline()
            return
        }
        playbackSlider.isEnabled = true
        playbackSlider.maxValue = times[1]
        if !isDragging { playbackSlider.doubleValue = times[0] }
        playbackSlider.toolTip = "\(formatTime(times[0])) / \(formatTime(times[1]))"
    }

    private func clearPlaybackTimeline() {
        playbackSlider.isEnabled = false
        playbackSlider.doubleValue = 0
        playbackSlider.maxValue = 0
        playbackSlider.toolTip = nil
    }

    func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    @objc func seek(_ sender: NSSlider) {
        guard playerReady, sender.isEnabled, pendingSkips == 0, sender.doubleValue.isFinite else { return }
        pendingSeek = (sender.doubleValue, playlistIndex)
        flushPlayerState()
    }
    @objc func skipVideo() {
        guard playerReady, !interactionsSuspended else { return }
        pendingSkips += 1
        pendingSeek = nil
        playbackSlider.isEnabled = false
        playbackSlider.doubleValue = 0
        flushPlayerState()
    }

    @objc func sound() {
        muted.toggle()
        if !muted && volume <= 0 {
            volume = 70
            UserDefaults.standard.set(volume, forKey: "volume")
        }
        UserDefaults.standard.set(!muted, forKey: "soundEnabled")
        syncVolumeControls()
        updatePlayer()
    }
    func syncVolumeControls() {
        volumeSlider.doubleValue = muted ? 0 : volume
        volumeButton.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: "Toggle sound")
        muteItem.state = muted ? .off : .on
        muteItem.title = muted ? "Unmute" : "Mute"
        syncStatusMenu()
    }
    @objc func changeVolume(_ sender: NSSlider) {
        volume = sender.doubleValue
        muted = volume == 0
        UserDefaults.standard.set(volume, forKey: "volume")
        UserDefaults.standard.set(!muted, forKey: "soundEnabled")
        syncVolumeControls()
        updatePlayer()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        playerReady = true
        skipButton.isEnabled = true
        updatePlayer()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }
    @objc func reload() {
        guard let bundledURL = Bundle.main.url(forResource: "player", withExtension: "html") else { return }
        let url = (try? VideoLibrary.user.playerURL(bundledPlayer: bundledURL)) ?? bundledURL
        playerGeneration += 1
        playbackRevision = 0
        playerReady = false
        pendingSeek = nil
        pendingSkips = 0
        playerJavaScriptInFlight = false
        playerStateDirty = true
        playbackSlider.isEnabled = false
        skipButton.isEnabled = false
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}
