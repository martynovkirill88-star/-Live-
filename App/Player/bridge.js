window.icon = name => '<svg class="icon" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><use href="#'+name+'"></use></svg>';
window.mountBundledPlayer = item => {
    window.activePlayer?.destroy();
    const root = document.getElementById('player');
    window.activePlayer = window.createLivePlayer(root, item);
    root.querySelector('.fullscreen').onclick = () => {
        window.webkit?.messageHandlers.playerOrientation.postMessage(true);
    };
};


