window.icon = name => '<svg class="icon" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><use href="#'+name+'"></use></svg>';
window.mountBundledPlayer = item => {
    window.activePlayer?.destroy();
    window.activePlayer = window.createLivePlayer(document.getElementById('player'), item);
};

document.addEventListener('fullscreenchange', () => {
    window.webkit?.messageHandlers.playerOrientation.postMessage(Boolean(document.fullscreenElement));
});
document.addEventListener('webkitbeginfullscreen', () => {
    window.webkit?.messageHandlers.playerOrientation.postMessage(true);
}, true);
document.addEventListener('webkitendfullscreen', () => {
    window.webkit?.messageHandlers.playerOrientation.postMessage(false);
}, true);
