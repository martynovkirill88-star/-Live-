window.icon = name => '<svg class="icon" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><use href="#'+name+'"></use></svg>';
window.mountBundledPlayer = item => {
    window.activePlayer?.destroy();
    const root = document.getElementById('player');
    window.activePlayer = window.createLivePlayer(root, item);
    const video = root.querySelector('video');
    let lastSent = 0;
    function saveProgress(finished, force) {
        if (item.live || !Number.isFinite(video.currentTime) || (!finished && video.currentTime < 0.5)) return;
        const now = Date.now();
        if (!force && now - lastSent < 5000) return;
        lastSent = now;
        window.webkit?.messageHandlers.playerProgress?.postMessage({
            position: video.currentTime, observed: now / 1000, finished
        });
    }
    video.addEventListener('timeupdate', () => { if (!video.paused && !video.seeking) saveProgress(false, false); });
    video.addEventListener('pause', () => { if (!video.ended && !video.seeking) saveProgress(false, true); });
    video.addEventListener('ended', () => saveProgress(true, true));
    document.addEventListener('visibilitychange', () => {
        if (document.hidden && !video.ended) saveProgress(false, true);
    });
    let watched = 0, previousTick = 0;
    video.addEventListener('timeupdate', () => {
        const now = performance.now();
        if (!video.paused && previousTick) watched += Math.min(1, (now - previousTick) / 1000);
        previousTick = now;
        if (watched >= 30) {
            window.webkit?.messageHandlers.playerWatched.postMessage(true);
            watched = -Infinity;
        }
    });
    root.querySelector('.fullscreen').onclick = () => {
        window.webkit?.messageHandlers.playerOrientation.postMessage(true);
    };
};



