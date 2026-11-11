window.icon = name => '<svg class="icon" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><use href="#'+name+'"></use></svg>';
window.mountBundledPlayer = item => {
    window.activePlayer?.destroy();
    const root = document.getElementById('player');
    window.activePlayer = window.createLivePlayer(root, item);
    const video = root.querySelector('video');
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



