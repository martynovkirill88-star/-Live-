// Local media uses the same player controls as streaming video.
window.attachOfflineMedia = (video,item) => {
 const state={position:0,duration:item.duration||0,paused:true,ready:false,muted:false,volume:1};
 const send=(command,value)=>window.webkit.messageHandlers.offlineMedia.postMessage({command,value:value??0});
 const property=(name,get,set)=>Object.defineProperty(video,name,{configurable:true,get,set});
 property('currentTime',()=>state.position,value=>{state.position=value;send('seek',value);});
 property('duration',()=>state.duration);property('paused',()=>state.paused);
 property('ended',()=>state.duration>0&&state.position>=state.duration-.1);
 property('readyState',()=>state.ready?4:0);property('seeking',()=>false);
 property('videoHeight',()=>Number.parseInt(item.offlineQuality)||720);property('videoWidth',()=>0);
 property('muted',()=>state.muted,value=>{state.muted=value;send('mute',value?1:0);});
 property('volume',()=>state.volume,value=>{state.volume=value;send('volume',value);});
 const ranges={get length(){return state.ready?1:0},start:()=>0,end:()=>state.duration};
 property('buffered',()=>ranges);property('seekable',()=>ranges);
 video.play=()=>{send('play');return Promise.resolve();};video.pause=()=>send('pause');video.load=()=>{};
 video.requestVideoFrameCallback=undefined;
 window.updateOfflineMedia=next=>{
  const wasReady=state.ready,wasPaused=state.paused;Object.assign(state,next);
  if(!wasReady&&state.ready)for(const event of ['loadedmetadata','loadeddata','canplay'])video.dispatchEvent(new Event(event));
  if(wasPaused!==state.paused)video.dispatchEvent(new Event(state.paused?'pause':'playing'));
  video.dispatchEvent(new Event('timeupdate'));video.dispatchEvent(new Event('seeked'));
  if(next.failure)document.querySelector('.player-message').textContent=next.failure;
 };
};
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



