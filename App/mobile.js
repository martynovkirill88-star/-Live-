(() => {
    if (location.origin !== 'https://live.chepushkavpn.fun') return;
    const root = document.querySelector('#app');
    const footer = document.querySelector('.mobile-nav');
    if (!root || !footer) return;
    document.documentElement.classList.add('ios-live');

    const style = document.createElement('style');
    style.textContent = `
      .ios-live body { background:#0c1211; color:#f2f6f3; }
      .ios-live .topbar { background:#0c1211; border:0; padding-inline:16px; gap:12px; }
      .ios-live .brand { font-size:17px; white-space:nowrap; }
      .ios-live .brand-icon { border-radius:50%; background:#cafa75; }
      .ios-live .brand-live { display:none; }
      .ios-live .mobile-nav { background:#131e1a; border-color:#26352f; padding-bottom:max(12px,env(safe-area-inset-bottom)); }
      .ios-live .mobile-nav .ios-current { color:#cafa75; }
      .ios-live .ios-home .grid { grid-template-columns:minmax(0,1fr); gap:16px; }
      .ios-live .ios-home .card { background:transparent; border:0; }
      .ios-live .ios-home .thumbnail { border-radius:14px; }
      .ios-live .ios-home .card-info { padding-inline:0; }
      .ios-live .ios-home .catalog-head h1 { font-size:24px; margin:0; }
      .ios-live .ios-home .catalog-count,.ios-live .ios-home .catalog-section-heading { display:none; }
      .ios-live .ios-categories { display:flex; gap:8px; overflow:auto; margin:0 0 16px; }
      .ios-live .ios-categories a { background:#1b2925; border-radius:10px; color:#f2f6f3; white-space:nowrap; padding:9px 14px; }
      .ios-live .ios-categories a:first-child { background:#cafa75; color:#132018; }
      .ios-live .public-channel-head { display:flex; flex-direction:column; align-items:flex-start; gap:12px; background:#14201c; border-radius:16px; padding:20px; }
      .ios-live .public-channel-actions { margin:0; width:100%; }
      .ios-live .public-channel .grid { grid-template-columns:minmax(0,1fr); gap:12px; }
      .ios-live .public-channel .card { display:grid; grid-template-columns:32% 1fr; gap:12px; background:transparent; border:0; align-items:center; }
      .ios-live .public-channel .card-info { padding:0; }
      .ios-live .public-channel .card-info .avatar { display:none; }
      .ios-live .watch-description,.ios-live #videoComments { border-radius:16px; background:#14201c; }
      .ios-live .ios-watch .mobile-nav { display:none; }
    `;
    document.head.append(style);
    const brand = document.querySelector('.brand > span:last-child');
    if (brand) brand.textContent = 'Чепушка Live';

    const profile = footer.lastElementChild;
    profile.href = '#profile';
    profile.removeAttribute('data-route');
    profile.querySelector('use').setAttribute('href', '/icons.svg#user-round');
    profile.querySelector('small').textContent = 'Профиль';
    profile.addEventListener('click', event => {
        event.preventDefault();
        document.querySelector('.account-button')?.click();
    });
    const saved = footer.children[2];
    saved.href = '/saved';
    saved.querySelector('use').setAttribute('href', '/icons.svg#bookmark');
    saved.querySelector('small').textContent = 'Сохранённое';

    function updateScreen() {
        const home = location.pathname === '/' && !location.search;
        document.body.classList.toggle('ios-home', home);
        document.body.classList.toggle('ios-watch', location.pathname.startsWith('/watch/'));
        for (const link of footer.querySelectorAll('a')) {
            link.classList.toggle('ios-current', link.pathname === location.pathname && !link.hash);
        }
        if (!home) return;
        const heading = root.querySelector('.catalog-head h1');
        if (!heading || heading.textContent === 'Для вас') return;
        heading.textContent = 'Для вас';
        const filters = document.createElement('nav');
        filters.className = 'ios-categories';
        filters.setAttribute('aria-label', 'Категории');
        filters.innerHTML = '<a href="/" data-route>Всё</a><a href="/live" data-route>В эфире</a><a href="/?q=музыка" data-route>Музыка</a><a href="/?q=путешествия" data-route>Путешествия</a>';
        root.prepend(filters);
    }
    new MutationObserver(updateScreen).observe(root, {childList: true});
    updateScreen();
})();
