window.createLivePlayer = function(container,item,onWatched=()=>{}) {
  const I=window.icon,esc=v=>String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const time=n=>Number.isFinite(n)?`${Math.floor(n/60)}:${String(Math.floor(n%60)).padStart(2,'0')}`:'0:00';
  container.className='player player-refined';
  container.innerHTML=`<video playsinline preload="none" ${item.poster?`poster="${esc(item.poster)}"`:''}></video><canvas class="player-hold" hidden></canvas><button class="center-play" aria-label="Начать просмотр">${I('play')}</button><div class="player-loading" role="status" aria-label="Загрузка видео" hidden><div class="player-loading-animation" aria-hidden="true"></div><span class="sr-only">Загрузка видео…</span></div><div class="player-message" role="status"></div><div class="player-toolbar"><div class="timeline"><div class="timeline-rail"><div class="buffered"></div><div class="played"></div></div><span class="seek-thumb"></span><div class="seek-preview" hidden><img alt="Предпросмотр выбранного момента" hidden><span class="preview-time"></span></div><input class="seek" aria-label="Позиция воспроизведения" type="range" min="0" max="1000" value="0"></div><button class="play" aria-label="Воспроизвести">${I('play')}</button><button class="mute" aria-label="Выключить звук">${I('volume-2')}</button><input class="volume" type="range" aria-label="Громкость" min="0" max="1" step="0.05" value="1"><span class="player-time">0:00</span>${item.live?'<button class="player-live" aria-label="Перейти к прямому эфиру"><span class="live-dot"></span>В эфир</button>':''}<div class="quality-wrap"><button class="quality-toggle" aria-label="Качество видео" aria-expanded="false">${I('settings-2')}<span class="quality-label">Авто</span></button><div class="quality-menu" role="menu" aria-label="Выбор качества" hidden><div class="quality-heading">Качество</div><button role="menuitemradio" aria-checked="true" data-quality="auto"><span>Авто</span><small>По скорости интернета</small>${I('check')}</button>${[...item.qualities].sort((a,b)=>b.height-a.height).map(q=>`<button role="menuitemradio" aria-checked="false" data-quality="${esc(q.code)}"><span>${q.height}p${q.fps>=50?'60':''}</span>${q.source?'<small>Исходное</small>':'<small></small>'}${I('check')}</button>`).join('')}</div></div><button class="pip" aria-label="Картинка в картинке">${I('picture-in-picture-2')}</button><button class="fullscreen" aria-label="Полный экран">${I('maximize')}</button></div>`;
  const v=container.querySelector('video'),msg=container.querySelector('.player-message'),play=container.querySelector('.play'),center=container.querySelector('.center-play'),seek=container.querySelector('.seek'),label=container.querySelector('.quality-label'),toggle=container.querySelector('.quality-toggle'),menu=container.querySelector('.quality-menu');
  v.disableRemotePlayback=true;
  let watched=0,lastWatchTick=0,counted=false;
  const viewThreshold=Math.max(.2,Math.min(5,(item.duration||20)*.3));
  v.addEventListener('timeupdate',()=>{const tick=performance.now();if(!v.paused&&lastWatchTick)watched+=Math.min(1,(tick-lastWatchTick)/1000);lastWatchTick=tick;if(!counted&&watched>=viewThreshold){counted=true;onWatched();}});
  let raf=0,dragging=false,dragPercent=null,bufferStamp=0;
  let streamStarted=false,previewTimer=0,previewBucket=null;
  let hls=null,dead=false,retries=0,timer,bufferTimer,mediaErrorTimer,choice='auto',actual=0,estimate=6000000,restore=null,autoplay=false,loading=false;
  const loader=container.querySelector('.player-loading');
  const reducedMotion=window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const loaderAnimation=window.lottie?lottie.loadAnimation({container:loader.querySelector('.player-loading-animation'),renderer:'svg',loop:true,autoplay:false,animationData:window.playerLoading,rendererSettings:{progressiveLoad:true}}):null;
  function buffering(active){
    if(dead)return;
    loader.hidden=!active;container.setAttribute('aria-busy',String(active));
    if(active){center.hidden=true;if(loaderAnimation&&!reducedMotion)loaderAnimation.play();}
    else if(loaderAnimation)loaderAnimation.pause();
  }
  function say(t){clearTimeout(bufferTimer);if(t){loading=false;buffering(false);}msg.textContent=t;}
  function ready(){if(v.readyState>=3&&!v.seeking){loading=false;buffering(false);say('');center.hidden=!v.paused;}}
  if(loaderAnimation)loaderAnimation.addEventListener('DOMLoaded',()=>{if(!loader.hidden&&!reducedMotion)loaderAnimation.play();});
  function qualityLabel(){const q=item.qualities.find(q=>q.code===choice);label.textContent=choice==='auto'?'Авто'+(actual?' · '+actual+'p':''):q.height+'p'+(q.fps>=50?'60':'');}
  function start(){if(hls&&!streamStarted){hls.startLoad(v.currentTime||-1);streamStarted=true;}center.hidden=true;if(v.readyState<3)buffering(true);v.play().catch(()=>{if(!loading){buffering(false);center.hidden=false;}say('');});}
  function load(position=null,playing=false){
    bufferedBar.innerHTML='';bufferStamp=0;restore=position;autoplay=playing;streamStarted=false;loading=playing||position!==null;say('');buffering(loading);
    const hold=container.querySelector('.player-hold');if(v.videoWidth&&v.readyState>=2){try{hold.width=Math.min(v.videoWidth,1280);hold.height=Math.round(hold.width*v.videoHeight/v.videoWidth);hold.getContext('2d').drawImage(v,0,0,hold.width,hold.height);hold.hidden=false;}catch{hold.hidden=true;}}
    if(hls){estimate=Math.max(1000000,hls.bandwidthEstimate||estimate);hls.destroy();hls=null;v.removeAttribute('src');v.load();}
    const url=item.manifest+'?quality='+encodeURIComponent(choice);
    if(!(window.Hls&&Hls.isSupported())&&v.canPlayType('application/vnd.apple.mpegurl')){v.src=url;v.load();}
    else if(window.Hls&&Hls.isSupported()){
      hls=new Hls({autoStartLoad:false,testBandwidth:false,startLevel:-1,startPosition:position??-1,abrEwmaDefaultEstimate:estimate,capLevelToPlayerSize:false,maxBufferLength:6,maxMaxBufferLength:8,maxBufferSize:3*1024*1024,backBufferLength:6,liveSyncDurationCount:3,liveMaxLatencyDurationCount:8,maxLiveSyncPlaybackRate:1.03,enableWorker:true});
      hls.loadSource(url);hls.attachMedia(v);
      hls.on(Hls.Events.MANIFEST_PARSED,()=>{const levels=hls.levels;let first=0;for(let i=0;i<levels.length;i++){if(levels[i].height<=720&&levels[i].bitrate<estimate*.85)first=i;}hls.startLevel=first;if(playing||position!==null){hls.startLoad(position??-1);streamStarted=true;}});
      hls.on(Hls.Events.LEVEL_SWITCHED,(_,data)=>{actual=hls.levels[data.level]?.height||0;qualityLabel();});
      hls.on(Hls.Events.ERROR,(_,data)=>{if(!data.fatal||dead)return;if(data.type===Hls.ErrorTypes.MEDIA_ERROR&&retries++<2)hls.recoverMediaError();else if(data.type===Hls.ErrorTypes.NETWORK_ERROR&&retries++<4){say('');buffering(true);setTimeout(()=>{if(hls&&!dead)hls.startLoad();},1500);}else{say('Видео недоступно. Повторите попытку.');center.hidden=false;}});
    }else{v.controls=true;say('Откройте видео в Safari или Chrome.');}
  }
  v.addEventListener('loadeddata',()=>{container.querySelector('.player-hold').hidden=true;});
  v.addEventListener('loadedmetadata',()=>{if(restore!==null){const end=v.seekable.length?v.seekable.end(v.seekable.length-1):v.duration;v.currentTime=Math.min(restore,Number.isFinite(end)?Math.max(0,end-.1):restore);restore=null;}if(autoplay)start();});
  play.onclick=center.onclick=()=>{if(v.paused){if(v.error){retries=0;load(v.currentTime,true);}start();}else v.pause();};v.onclick=()=>play.click();
  v.addEventListener('playing',()=>{loading=false;buffering(false);say('');center.hidden=true;play.innerHTML=I('pause');play.setAttribute('aria-label','Пауза');retries=0;wake();});
  v.addEventListener('pause',()=>{if(hls&&!loading){hls.stopLoad();streamStarted=false;}if(!loading)buffering(false);play.innerHTML=I('play');play.setAttribute('aria-label','Воспроизвести');center.hidden=loading;container.classList.remove('user-inactive');});
  v.addEventListener('waiting',()=>{clearTimeout(bufferTimer);if(!v.paused||loading)bufferTimer=setTimeout(()=>{if(!dead&&(!v.paused||loading)&&v.readyState<3)buffering(true);},120);});
  v.addEventListener('stalled',()=>{if((!v.paused||loading)&&v.readyState<3)buffering(true);});
  v.addEventListener('seeking',()=>{if(!dragging)buffering(true);});
  v.addEventListener('seeked',ready);
  v.addEventListener('canplay',ready);
  v.addEventListener('error',()=>{clearTimeout(mediaErrorTimer);mediaErrorTimer=setTimeout(()=>{if(dead||!v.error)return;say('Не удалось загрузить видео. Повторите попытку.');center.hidden=false;},600);});
  v.addEventListener('ended',()=>{loading=false;buffering(false);say('');center.hidden=false;});
  function bounds(){return item.live&&v.seekable.length?[v.seekable.start(0),v.seekable.end(v.seekable.length-1)]:[0,v.duration];}
  const timeline=container.querySelector('.timeline'),played=container.querySelector('.played'),bufferedBar=container.querySelector('.buffered'),clock=container.querySelector('.player-time');
  function paint(percent){seek.value=Math.round(percent*10);played.style.width=percent+'%';timeline.style.setProperty('--seek',percent+'%');}
  let frameClock=null,frameCallback=0,smoothPosition=null,previousPaint=performance.now();
  function followFrames(now,metadata){frameClock={media:metadata.mediaTime,wall:metadata.expectedDisplayTime||now};if(!dead)frameCallback=v.requestVideoFrameCallback(followFrames);}
  if(v.requestVideoFrameCallback)frameCallback=v.requestVideoFrameCallback(followFrames);
  v.addEventListener('seeking',()=>{frameClock=null;smoothPosition=null;});
  v.addEventListener('pause',()=>{frameClock=null;smoothPosition=null;});
  function displayPosition(){const now=performance.now(),dt=Math.min(.1,(now-previousPaint)/1000);previousPaint=now;let target=v.currentTime;if(!v.paused&&!v.seeking&&v.readyState>=3&&frameClock)target=frameClock.media+Math.max(0,Math.min(.25,(now-frameClock.wall)/1000))*v.playbackRate;if(v.paused||v.seeking||v.readyState<3||smoothPosition===null||Math.abs(target-smoothPosition)>.6)smoothPosition=target;else{const predicted=smoothPosition+dt*v.playbackRate;smoothPosition=predicted+(target-predicted)*Math.min(1,dt*10);}return smoothPosition;}
  function progress(){
    const [begin,end]=bounds(),span=end-begin;if(!(span>0&&Number.isFinite(span)))return;
    if(!dragging)paint(Math.max(0,Math.min(100,(displayPosition()-begin)/span*100)));
    const now=performance.now();if(now-bufferStamp>400){bufferStamp=now;let html='';for(let i=0;i<v.buffered.length;i++){const a=Math.max(begin,v.buffered.start(i)),b=Math.min(end,v.buffered.end(i));if(b>a)html+=`<span style="left:${(a-begin)/span*100}%;width:${(b-a)/span*100}%"></span>`;}bufferedBar.innerHTML=html;}
    if(!dragging)clock.textContent=item.live?(end-v.currentTime<5?'В прямом эфире':'−'+time(end-v.currentTime)):time(v.currentTime)+' / '+time(v.duration);
    const live=container.querySelector('.player-live');if(live)live.classList.toggle('at-edge',end-v.currentTime<5);
    if(v.videoHeight&&actual!==v.videoHeight){actual=v.videoHeight;qualityLabel();}
  }
  function animation(){if(dead)return;progress();raf=requestAnimationFrame(animation);}raf=requestAnimationFrame(animation);
  function commit(value){const [a,b]=bounds();if(!Number.isFinite(b)||b<=a)return;const target=Math.min(b-.05,Math.max(a,a+(b-a)*value/100));const playing=!v.paused;dragging=false;timeline.classList.remove('dragging');if(hls&&choice==='auto'&&target>=v.currentTime&&target-v.currentTime<1){v.currentTime=target;return;}load(target,playing);}
  timeline.addEventListener('pointerdown',e=>{if(e.button!==0&&e.pointerType==='mouse')return;e.preventDefault();dragging=true;timeline.classList.add('dragging');timeline.setPointerCapture(e.pointerId);clearTimeout(timer);move(e);});
  function move(e){const rect=timeline.getBoundingClientRect();if(!dragging){showPreview(Math.max(0,Math.min(100,(e.clientX-rect.left)/rect.width*100)));return;}dragPercent=Math.max(0,Math.min(100,(e.clientX-rect.left)/rect.width*100));paint(dragPercent);showPreview(dragPercent);const [a,b]=bounds();if(Number.isFinite(b))clock.textContent=item.live?'−'+time((b-a)*(1-dragPercent/100)):time(a+(b-a)*dragPercent/100)+' / '+time(b);}
  timeline.addEventListener('pointermove',move);timeline.addEventListener('pointerup',e=>{if(!dragging)return;move(e);const value=dragPercent;dragging=false;if(timeline.hasPointerCapture(e.pointerId))timeline.releasePointerCapture(e.pointerId);commit(value);if(e.pointerType==='touch')hidePreview();wake();});timeline.addEventListener('pointercancel',()=>{dragging=false;timeline.classList.remove('dragging');hidePreview();wake();});
  timeline.addEventListener('pointerleave',()=>{if(!dragging)hidePreview();});
  const preview=timeline.querySelector('.seek-preview'),previewImage=preview.querySelector('img'),previewTime=preview.querySelector('.preview-time');
  function hidePreview(){clearTimeout(previewTimer);preview.hidden=true;}
  function showPreview(percent){const [a,b]=bounds();if(!Number.isFinite(b)||b<=a)return;const target=Math.min(b-.1,a+(b-a)*percent/100),bucket=Math.floor(target/10)*10;preview.hidden=false;const width=timeline.clientWidth,half=preview.offsetWidth/2;preview.style.left=Math.max(half,Math.min(width-half,width*percent/100))+'px';previewTime.textContent=item.live?'−'+time(b-target):time(target);if(bucket===previewBucket)return;previewBucket=bucket;previewImage.hidden=true;clearTimeout(previewTimer);previewTimer=setTimeout(()=>{if(dead||preview.hidden)return;const source=item.origin+'/api/media/'+encodeURIComponent(item.id)+'/preview?t='+bucket;previewImage.onload=()=>{if(previewBucket===bucket)previewImage.hidden=false;};previewImage.onerror=()=>{if(previewBucket===bucket)previewBucket=null;};previewImage.src=source;},140);}
  seek.oninput=()=>{dragging=true;timeline.classList.add('dragging');paint(Number(seek.value)/10);showPreview(Number(seek.value)/10);};seek.onchange=()=>{dragging=false;commit(Number(seek.value)/10);};
  const mute=container.querySelector('.mute');mute.onclick=()=>{v.muted=!v.muted;mute.innerHTML=I(v.muted?'volume-x':'volume-2');mute.setAttribute('aria-label',v.muted?'Включить звук':'Выключить звук');};container.querySelector('.volume').oninput=e=>{v.volume=Number(e.target.value);v.muted=false;e.target.style.setProperty('--volume',Math.round(v.volume*100)+'%');mute.innerHTML=I(v.volume===0?'volume-x':'volume-2');};
  toggle.onclick=()=>{menu.hidden=!menu.hidden;toggle.setAttribute('aria-expanded',String(!menu.hidden));wake();};
  menu.onclick=e=>{const button=e.target.closest('[data-quality]');if(!button)return;choice=button.dataset.quality;menu.querySelectorAll('[data-quality]').forEach(b=>b.setAttribute('aria-checked',String(b===button)));qualityLabel();menu.hidden=true;toggle.setAttribute('aria-expanded','false');const position=item.live&&v.seekable.length?Math.min(v.currentTime,v.seekable.end(v.seekable.length-1)-2):v.currentTime;load(position,!v.paused);};
  function outside(e){if(!e.target.closest('.quality-wrap')){menu.hidden=true;toggle.setAttribute('aria-expanded','false');}}document.addEventListener('pointerdown',outside);
  const live=container.querySelector('.player-live');if(live)live.onclick=()=>{if(v.seekable.length)load(v.seekable.end(v.seekable.length-1)-4,true);else start();};
  container.querySelector('.fullscreen').onclick=()=>{if(document.fullscreenElement)document.exitFullscreen();else if(container.requestFullscreen)container.requestFullscreen().catch(()=>{});else if(v.webkitEnterFullscreen)v.webkitEnterFullscreen();};
  const pip=container.querySelector('.pip');pip.hidden=!document.pictureInPictureEnabled;pip.onclick=()=>{(document.pictureInPictureElement?document.exitPictureInPicture():v.requestPictureInPicture()).catch(()=>{});};
  function wake(){container.classList.remove('user-inactive');clearTimeout(timer);timer=setTimeout(()=>{if(!v.paused&&menu.hidden&&!dragging)container.classList.add('user-inactive');},2500);}
  container.onpointermove=wake;container.onpointerdown=wake;container.onkeydown=e=>{if(e.key==='Escape'){menu.hidden=true;return;}if(e.target.matches('input,button'))return;if(e.key===' '){e.preventDefault();play.click();}wake();};container.tabIndex=0;load(!item.live&&Number.isFinite(item.resume)&&item.resume>=5?item.resume:null);wake();
  function updateQualities(qualities){
    if(JSON.stringify(item.qualities)===JSON.stringify(qualities))return;
    item.qualities=qualities;
    menu.querySelectorAll('[data-quality]').forEach(b=>{if(b.dataset.quality!=='auto')b.remove();});
    menu.insertAdjacentHTML('beforeend',[...qualities].sort((a,b)=>b.height-a.height).map(q=>`<button role="menuitemradio" aria-checked="${choice===q.code}" data-quality="${esc(q.code)}"><span>${q.height}p${q.fps>=50?'60':''}</span>${q.source?'<small>Исходное</small>':'<small></small>'}${I('check')}</button>`).join(''));
    if(choice!=='auto'&&!qualities.some(q=>q.code===choice))choice='auto';
    qualityLabel();
  }
  return {updateQualities,get isPlaying(){return !v.paused&&!v.ended;},destroy(){dead=true;if(frameCallback&&v.cancelVideoFrameCallback)v.cancelVideoFrameCallback(frameCallback);clearTimeout(previewTimer);previewImage.removeAttribute('src');cancelAnimationFrame(raf);clearTimeout(mediaErrorTimer);clearTimeout(timer);clearTimeout(bufferTimer);document.removeEventListener('pointerdown',outside);if(loaderAnimation)loaderAnimation.destroy();v.pause();v.removeAttribute('src');v.load();if(hls)hls.destroy();}};
};

