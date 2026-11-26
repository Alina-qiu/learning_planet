(async () => {
  'use strict';
  const pages = {
    home: ['冒险大厅', 'planet'],
    book: ['错题宝库', 'book'],
    tasks: ['任务中心', 'list'],
    shop: ['奖励商店', 'gift'],
    review: ['今日错题复习', 'pencil'],
    parent: ['家长控制台', 'lock'],
  };
  const symbols = {
    planet: '◉', book: '▤', list: '☷', gift: '✧', pencil: '✎',
    star: '★', check: '✓', clock: '◷', coin: '◈', arrow: '→',
    spark: '✦', receipt: '▥', lock: '⌾', plus: '＋',
  };
  const escaped = {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'};
  const ui = {
    esc: (value) => String(value ?? '').replace(/[&<>"']/g, (char) => escaped[char]),
    icon: (name) => '<span class="symbol" aria-hidden="true">' + (symbols[name] || '') + '</span>',
  };
  const noticeKey = window.PlanetDemoModel.storageKey + '.changed';
  let channel;
  try { channel = new BroadcastChannel(noticeKey); } catch (_) { /* Some file viewers block origin APIs. */ }
  const store = await window.PlanetDemoModel.openBrowser(revision => {
    try { channel?.postMessage(revision); } catch (_) { /* Can still refresh on focus. */ }
    if (!channel) {
      try { window.localStorage.setItem(noticeKey, String(revision)); } catch (_) { /* Optional notification. */ }
    }
  });
  const content = document.getElementById('content');
  const title = document.querySelector('h1');
  const feedback = document.getElementById('feedback');
  let current;
  let timer;
  let generation;
  let routeEpoch = 0;
  const pending = new Set();
  document.querySelector('.tabs').innerHTML = ['home', 'book', 'tasks', 'shop'].map((view) =>
    '<a href="#' + view + '" data-view="' + view + '">' + ui.icon(pages[view][1]) + '<span>' + pages[view][0] + '</span></a>'
  ).join('');

  function notify(message) {
    window.clearTimeout(timer);
    feedback.textContent = message || '';
    if (message) timer = window.setTimeout(() => { feedback.textContent = ''; }, 4200);
  }

  function updateStorageNote(available) {
    document.querySelector('.local-note').textContent = available
      ? '演示家庭的数据保存在当前浏览器，请使用示例内容。'
      : '当前浏览器无法保存演示记录。你仍可体验，关闭页面后记录会消失。';
  }

  function draw() {
    const state = store.read();
    generation = state.generation;
    updateStorageNote(state.storageAvailable);
    const activeTab = current === 'review' ? 'book' : current;
    for (const link of document.querySelectorAll('.tabs a, .parent-entry')) {
      if (link.dataset.view === activeTab) link.setAttribute('aria-current', 'page');
      else link.removeAttribute('aria-current');
    }
    title.textContent = pages[current][0];
    document.title = '学习星球 · ' + pages[current][0];
    content.innerHTML = (current === 'parent' ? window.PlanetDemoParent : window.PlanetDemoChild).render(current, state, ui);
  }

  function route(moveFocus = true) {
    const name = location.hash.slice(1);
    const view = Object.hasOwn(pages, name) ? name : 'home';
    if (current === view) return;
    routeEpoch++;
    if (current === 'parent') store.act('parent-lock');
    notify('');
    current = view;
    draw();
    window.scrollTo(0, 0);
    if (moveFocus) document.getElementById('main').focus({preventScroll: true});
  }

  async function act(element, payload) {
    if (element.dataset.id) payload.id = element.dataset.id;
    const name = element.dataset.action;
    if (name === 'demo-reset' && !window.confirm('要恢复初始演示家庭吗？这会清除当前浏览器里添加的示例任务、错题、兑换记录及演示流水。')) return;
    const focused = document.activeElement;
    const submittedGeneration = generation;
    const submittedRoute = routeEpoch;
    const token = JSON.stringify([submittedRoute, submittedGeneration, name, payload.id || '']);
    if (pending.has(token)) return;
    pending.add(token);
    try {
      const message = await store.act(name, payload, {
        generation: submittedGeneration,
        current: () => routeEpoch === submittedRoute,
      });
      if (!message || routeEpoch !== submittedRoute) return;
      draw();
      notify(store.read().storageAvailable ? message : message + '（仅在当前标签页有效）');
      // Keep keyboard users near the action when the list or form is rebuilt.
      const match = Array.from(content.querySelectorAll('[data-action]')).find((node) =>
        node.dataset.action === name && node.dataset.id === element.dataset.id);
      const target = match?.matches('form') ? match.querySelector('input,select,textarea,button') : match;
      if (focused && target && !target.disabled) target.focus({preventScroll: true});
    } catch (error) {
      if (routeEpoch !== submittedRoute) return;
      if (!store.read().storageAvailable) updateStorageNote(false);
      if (name === 'parent-unlock') {
        draw();
        content.querySelector('input[name="pin"]')?.focus({preventScroll: true});
      }
      notify(error.message || '暂时无法保存，请再试一次。');
    } finally {
      pending.delete(token);
    }
  }

  document.addEventListener('click', (event) => {
    if (event.target.closest('.skip')) {
      event.preventDefault();
      document.getElementById('main').focus();
      return;
    }
    const nav = event.target.closest('[data-view]');
    if (nav && Object.hasOwn(pages, nav.dataset.view)) {
      if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      if (location.hash !== '#' + nav.dataset.view) location.hash = nav.dataset.view;
      return;
    }
    const button = event.target.closest('button[data-action]');
    if (!button || button.disabled) return;
    if (button.form?.dataset.action && button.type === 'submit') return;
    act(button, {});
  });
  document.addEventListener('submit', (event) => {
    const form = event.target;
    if (!form.dataset.action) return;
    event.preventDefault();
    act(form, Object.fromEntries(new FormData(form)));
  });
  window.addEventListener('hashchange', () => route());
  async function refreshFromDisk() {
    try {
      if (!await store.refresh()) return;
    } catch (_) {
      notify('暂时无法读取新的演示记录，请重新打开页面。');
      return;
    }
    const before = generation;
    const active = document.activeElement;
    // A second demo tab can approve a request while the child is typing.
    const drafts = [];
    for (const form of content.querySelectorAll('form[data-action]')) {
      if (form.dataset.action === 'parent-unlock') continue;
      const edits = Array.from(form.elements).filter(field => {
        if (!field.name || field.type === 'hidden') return false;
        if (field.tagName === 'SELECT') {
          const initial = Array.from(field.options).find(option => option.defaultSelected) || field.options[0];
          return field.value !== initial?.value;
        }
        return field.value !== field.defaultValue;
      }).map(field => [field.name, field.value]);
      if (edits.length || (active?.form === form && active.name)) {
        drafts.push({ action: form.dataset.action, id: form.dataset.id, hiddenId: form.elements.namedItem('id')?.value,
          edits, focus: active?.form === form ? active.name : null, open: form.closest('details')?.open });
      }
    }
    draw();
    if (before !== generation) return;
    const forms = Array.from(content.querySelectorAll('form[data-action]'));
    for (const draft of drafts) {
      const match = forms.find(form => form.dataset.action === draft.action && form.dataset.id === draft.id &&
        form.elements.namedItem('id')?.value === draft.hiddenId);
      if (!match) continue;
      for (const [name, value] of draft.edits) match.elements.namedItem(name).value = value;
      if (draft.open) match.closest('details').open = true;
      if (draft.focus) match.elements.namedItem(draft.focus)?.focus({preventScroll: true});
    }
  }
  if (channel) channel.onmessage = refreshFromDisk;
  window.addEventListener('storage', event => { if (event.key === noticeKey || event.key === null) refreshFromDisk(); });
  window.addEventListener('focus', refreshFromDisk);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshFromDisk(); });
  window.addEventListener('pagehide', () => {
    routeEpoch++;
    if (current === 'parent') store.act('parent-lock');
  });
  window.addEventListener('pageshow', event => { if (event.persisted) { draw(); refreshFromDisk(); } });
  route(false);
  refreshFromDisk();
})();
