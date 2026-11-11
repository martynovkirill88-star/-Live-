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
    saved.href = '#subscriptions';
    saved.querySelector('use').setAttribute('href', '/icons.svg#bookmark');
    saved.querySelector('small').textContent = 'Подписки';
    saved.removeAttribute('data-route');
    saved.addEventListener('click', async event => {
        event.preventDefault();
        if (document.querySelector('#iosSubscriptions')) return;
        const dialog = document.createElement('div');
        dialog.id = 'iosSubscriptions';
        dialog.setAttribute('role', 'dialog');
        dialog.setAttribute('aria-label', 'Подписки');
        dialog.style.cssText = 'position:fixed;inset:0;z-index:9999;background:#0c1211;padding:24px;overflow:auto';
        const close = document.createElement('button');
        close.textContent = 'Назад';
        close.onclick = () => dialog.remove();
        const title = document.createElement('h1');
        title.textContent = 'Подписки';
        const list = document.createElement('div');
        list.textContent = 'Загружаем каналы…';
        dialog.append(close, title, list);
        document.body.append(dialog);
        close.focus();
        try {
            const read = async path => {
                const response = await fetch(path);
                if (!response.ok) throw new Error(String(response.status));
                return response.json();
            };
            const session = await read('/api/session');
            if (!session.account) {
                list.textContent = 'Войдите, чтобы посмотреть подписки.';
                const login = document.createElement('button');
                login.textContent = 'Войти';
                login.onclick = () => {
                    dialog.remove();
                    document.querySelector('.account-button')?.click();
                };
                list.append(document.createElement('br'), login);
                return;
            }
            const catalog = await read('/api/catalog');
            const ids = [...new Set(catalog.items.map(item => item.channel_id).filter(Boolean))];
            const channels = [];
            for (let index = 0; index < ids.length; index += 6) {
                if (!dialog.isConnected) return;
                channels.push(...await Promise.all(ids.slice(index, index + 6)
                    .map(id => read('/api/channels/' + encodeURIComponent(id)))));
            }
            list.textContent = '';
            for (const channel of channels.filter(channel => channel.subscribed)) {
                const link = document.createElement('a');
                link.href = '/channel/' + encodeURIComponent(channel.id);
                link.dataset.route = '';
                link.style.cssText = 'display:block;padding:14px 0';
                link.textContent = channel.profile.name;
                link.onclick = () => dialog.remove();
                list.append(link);
            }
            if (!list.children.length) list.textContent = 'В каталоге нет каналов, на которые вы подписаны.';
        } catch {
            list.textContent = 'Не удалось загрузить подписки. Закройте экран и попробуйте снова.';
        }
    });

    function updateScreen() {
        const home = location.pathname === '/' && !location.search;
        document.body.classList.toggle('ios-home', home);
        document.body.classList.toggle('ios-watch', location.pathname.startsWith('/watch/'));
        for (const link of footer.querySelectorAll('a')) {
            link.classList.toggle('ios-current', link.pathname === location.pathname && !link.hash);
        }
        const channel = root.querySelector('.public-channel');
        const poster = channel?.querySelector('.thumbnail img');
        if (poster && !channel.querySelector('.ios-channel-banner')) {
            const banner = document.createElement('img');
            banner.className = 'ios-channel-banner';
            banner.alt = '';
            banner.src = poster.src;
            banner.style.cssText = 'width:100%;height:100px;object-fit:cover;border-radius:14px;margin-bottom:8px';
            channel.prepend(banner);
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

