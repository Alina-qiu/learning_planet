(function () {
  'use strict';

  const taskLabels = { ready: '待开始', active: '进行中', paused: '已暂停', done: '已完成' };
  const requestLabels = { requested: '待家长审批', approved: '待家长兑现', rejected: '已拒绝', fulfilled: '已兑现' };
  const subjects = ['数学', '语文', '英语'];

  function action(ui, name, id, label, style) {
    return `<button type="button" class="${style}" data-action="${name}" data-id="${ui.esc(id)}">${label}</button>`;
  }

  function link(view, label, style = 'quiet') {
    return `<button type="button" class="${style}" data-view="${view}">${label}</button>`;
  }

  function ordinaryTask(task, ui) {
    const e = ui.esc;
    const buttons = {
      ready: () => action(ui, 'task-start', task.id, '开始', 'primary'),
      active: () => action(ui, 'task-complete', task.id, '完成任务', 'primary') + action(ui, 'task-pause', task.id, '暂停', 'secondary'),
      paused: () => action(ui, 'task-resume', task.id, '继续', 'primary'),
      done: () => '',
    };
    return `<article class="item">
      <div class="row"><span class="icon-box" aria-hidden="true">${ui.icon(task.status === 'done' ? 'check' : 'clock')}</span>
        <div><h3>${e(task.title)}</h3><p class="muted">${e(task.minutes)} 分钟 · ${e(task.rewardCoins)} 金币 · ${e(task.rewardXp)} XP</p></div></div>
      <div class="actions"><span class="badge">${taskLabels[task.status] || '待开始'}</span>${buttons[task.status]?.() || ''}</div>
    </article>`;
  }

  function reviewTask(state, ui) {
    const count = state.review.items.length;
    if (count === 0) return '';
    const status = state.review.status;
    const detail = status === 'ready' ? `本轮安排 ${count} 道到期题` : `已作答 ${state.review.answers.length} / ${count} 道`;
    return `<article class="item">
      <div class="row"><span class="icon-box" aria-hidden="true">${ui.icon('book')}</span>
        <div><h3>每日错题复习</h3><p class="muted">${detail}</p></div></div>
      <div class="actions"><span class="badge">${status === 'done' ? '已完成' : '自动复习任务'}</span>
        ${link('review', status === 'done' ? '查看记录' : status === 'active' ? '继续复习' : '去复习', status === 'done' ? 'quiet' : 'primary')}</div>
    </article>`;
  }

  function sortedTasks(state) {
    const order = { active: 0, paused: 1, ready: 2, done: 3 };
    return [...state.tasks].sort((left, right) => order[left.status] - order[right.status]);
  }

  function home(state, ui) {
    const level = Math.min(50, 1 + Math.floor((Math.sqrt(1 + 8 * Math.max(0, state.xp) / 100) - 1) / 2));
    const tasks = sortedTasks(state);
    const focus = tasks.find(task => task.status === 'active' || task.status === 'paused');
    return `<section class="hero">
      <div class="row"><span class="hero-avatar" aria-hidden="true">🧑‍🚀</span>
        <div><h2>${ui.esc(state.childName)}的星球</h2><p>星际探索员 · 等级 ${level}</p><p>连续学习 ${ui.esc(state.streakDays)} 天</p></div>
      </div>
      <div class="hero-planet" aria-hidden="true"></div>
    </section>
    <div class="metrics">
      <div class="metric"><span>${ui.icon('coin')} 可用金币</span><strong>${ui.esc(state.coins)}</strong><small>可以兑换奖励</small></div>
      <div class="metric"><span>${ui.icon('star')} 成长 XP</span><strong>${ui.esc(state.xp)}</strong><small>积累经验升级</small></div>
    </div>
    <section class="card"><div class="card-head"><h2>今天的任务</h2>${link('tasks', '查看全部')}</div>
      <div class="stack">${focus ? ordinaryTask(focus, ui) : ''}${reviewTask(state, ui)}
        ${tasks.filter(task => task !== focus).slice(0, focus ? 1 : 2).map(task => ordinaryTask(task, ui)).join('')}
        ${!tasks.length && !state.review.items.length ? '<p class="muted">今天还没有任务。</p>' : ''}
      </div>
    </section>`;
  }

  function tasksPage(state, ui) {
    const rows = sortedTasks(state);
    const repeat = rows.filter(task => task.repeat === 'mwf');
    return `<section class="card"><h2>今天的任务</h2><div class="stack">
      ${reviewTask(state, ui)}${rows.map(task => ordinaryTask(task, ui)).join('')}
      ${!rows.length && !state.review.items.length ? '<p class="muted">今天还没有任务。</p>' : ''}
    </div></section>
    ${repeat.length ? `<section class="card"><h2>我的每周计划</h2><div class="stack">${repeat.map(task =>
      `<div class="item"><div><h3>${ui.esc(task.title)}</h3><p class="muted">每周一、三、五 · 每次 ${ui.esc(task.minutes)} 分钟</p></div></div>`).join('')}</div></section>` : ''}`;
  }

  function book(state, ui) {
    const { status, items, answers, backlog } = state.review;
    const selected = new Set(items.map(q => q.id));
    const answered = new Set(answers.map(a => a.questionId));
    let progress = items.length ? `本轮安排 ${items.length} 道，每轮最多 10 道。` : '今天没有到期的错题。';
    if (status === 'active') progress = `本轮已作答 ${answered.size} / ${items.length} 道。`;
    if (status === 'done') progress = `本轮已完成 ${items.length} 道。`;
    function questionStatus(q) {
      if (!q.confirmed) return '待家长确认标准答案';
      if (answered.has(q.id)) return '本轮已作答';
      if (selected.has(q.id)) return '本轮待复习';
      return q.due ? '到期，留待下轮' : '已安排复测';
    }
    const grouped = subjects.map(subject => {
      const questions = state.questions.filter(q => q.subject === subject);
      if (!questions.length) return '';
      return `<details class="card" open><summary><strong>${subject}</strong> · ${questions.length} 道</summary>
        <div class="stack">${questions.map(q => `<div class="item"><div><h3>${ui.esc(q.prompt)}</h3>
        <p class="muted">${questionStatus(q)}</p></div></div>`).join('')}</div></details>`;
    }).join('');
    return `<section class="card"><div class="card-head"><div><h2>到期复习</h2>
      <p class="muted">${progress}</p>${backlog ? `<p class="muted">还有 ${ui.esc(backlog)} 道到期题留待下轮。</p>` : ''}</div>
      ${status !== 'ready' || items.length ? link('review', status === 'done' ? '查看复习记录' : '进入复习', 'primary') : ''}</div></section>
    <details class="card"><summary><strong>${ui.icon('pencil')} 手动录入错题</strong></summary>
      <form class="form" data-action="question-add">
        <label class="field">学科<select name="subject">${subjects.map(s => `<option>${s}</option>`).join('')}</select></label>
        <label class="field">题目<textarea name="prompt" rows="3" required maxlength="500"></textarea></label>
        <label class="field">标准答案<input name="answer" required maxlength="500" autocomplete="off"></label>
        <p class="muted">保存后请家长确认标准答案，再加入奖励复习。</p>
        <button class="primary" type="submit">保存错题</button>
      </form></details>
    ${grouped || '<section class="card"><h2>我的错题</h2><p class="muted">还没有错题，可以先手动录入一道。</p></section>'}`;
  }

  function review(state, ui) {
    const queue = state.review.items;
    const answers = state.review.answers;
    const answered = new Set(answers.map(a => a.questionId));
    if (state.review.status === 'ready') {
      return `<section class="card"><h2>今天的复习队列</h2>
        ${queue.length ? `<p>共 ${queue.length} 道题，全部答完会自动结算。</p>
        <ol>${queue.map(q => `<li><strong>${ui.esc(q.subject)}</strong> · ${ui.esc(q.prompt)}</li>`).join('')}</ol>
        <button type="button" class="primary" data-action="review-start">开始复习</button>` : `<p class="muted">今天没有到期的错题。</p>${link('book', '回错题宝库', 'secondary')}`}
      </section>`;
    }
    if (state.review.status === 'done') {
      return `<section class="card"><span class="icon-box" aria-hidden="true">${ui.icon('check')}</span>
        <h2>今天的复习完成了</h2><p>共作答 ${answers.length} 道，答对 ${answers.filter(a => a.correct).length} 道。</p>
        <p>本次入账 <strong>${ui.esc(state.review.settlement.coins)} 金币</strong> · <strong>${ui.esc(state.review.settlement.xp)} XP</strong></p>
        ${link('home', '回冒险大厅', 'primary')}</section>
        <section class="card"><h2>复习记录</h2><div class="stack">${queue.map(q => {
          const record = answers.find(a => a.questionId === q.id);
          if (!record) return '';
          return `<article class="item"><div><h3>${ui.esc(q.prompt)}</h3><p>我的答案：${ui.esc(record.submitted)}</p>
            ${record.correct ? '' : `<p>标准答案：${ui.esc(q.answer)}</p>`}<p class="muted">${record.correct ? '答对了 · 15 金币 · 15 XP' : '需要再练'} · ${ui.esc(record.confidence)}</p></div></article>`;
        }).join('')}</div></section>`;
    }
    const question = queue.find(q => !answered.has(q.id));
    if (!question) return `<section class="card"><h2>本轮已答完</h2>${link('tasks', '回任务中心', 'secondary')}</section>`;
    return `<section class="card"><span class="badge">第 ${answered.size + 1} / ${queue.length} 题 · ${ui.esc(question.subject)}</span>
      <h2>${ui.esc(question.prompt)}</h2>
      <form class="form" data-action="review-answer" data-id="${ui.esc(question.id)}">
        <label class="field">我的答案<input name="answer" required maxlength="500" autocomplete="off"></label>
        <label class="field">这次作答有多大把握？
          <select name="confidence" required><option value="" selected disabled>请选择</option><option>不确定</option><option>比较有把握</option><option>很有把握</option></select></label>
        <button class="primary" type="submit">${answered.size + 1 === queue.length ? '提交最后一题' : '提交答案'}</button>
      </form></section>`;
  }

  function shop(state, ui) {
    const e = ui.esc;
    function redeemButton(reward) {
      const pending = state.requests.find(request =>
        (request.rewardId === reward.id || request.title === reward.title) &&
        (request.status === 'requested' || request.status === 'approved'));
      if (pending) return `<button type="button" class="secondary" disabled>${requestLabels[pending.status]}</button>`;
      if (state.coins < reward.cost) return '<button type="button" class="secondary" disabled>金币不足</button>';
      return action(ui, 'reward-request', reward.id, '申请兑换', 'primary');
    }
    return `<section class="card"><div class="card-head"><div><h2>我的金币</h2>
      <p><strong>${e(state.coins)} 可用</strong> · ${e(state.frozen)} 已冻结</p></div><span class="icon-box" aria-hidden="true">${ui.icon('coin')}</span></div>
      <p class="muted">申请后先冻结金币，家长兑现奖励时扣除。拒绝会退回金币。</p></section>
      <section class="card"><h2>家庭奖励</h2><div class="stack">${state.rewards.map(reward => `<article class="item">
        <div class="row"><span class="icon-box" aria-hidden="true">${ui.icon('gift')}</span>
        <div><h3>${e(reward.title)}</h3><p class="muted">${e(reward.cost)} 金币</p></div></div>
        ${redeemButton(reward)}
      </article>`).join('') || '<p class="muted">还没有可兑换的家庭奖励。</p>'}</div></section>
      <section class="card"><h2>我的兑换记录</h2><div class="stack">${state.requests.map(request => `<div class="item">
        <div><h3>${e(request.title)}</h3><p class="muted">${e(request.cost)} 金币</p></div><span class="badge">${requestLabels[request.status] || '处理中'}</span></div>`).join('') || '<p class="muted">还没有兑换申请。</p>'}</div></section>`;
  }

  const pages = { home, tasks: tasksPage, book, review, shop };
  window.PlanetDemoChild = { render(view, state, ui) { return pages[view](state, ui); } };
})();
