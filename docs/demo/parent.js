(() => {
  'use strict';

  const requestStatus = {
    requested: '待审批', approved: '待履约', rejected: '已拒绝', fulfilled: '已履约',
  };

  function heading(icon, title, ui) {
    return `<div class="card-head"><h2>${title}</h2><span class="icon-box" aria-hidden="true">${ui.icon(icon)}</span></div>`;
  }

  function pinForm(state, ui) {
    const locked = state.pinLockedUntil > Date.now();
    const retry = locked ? new Date(state.pinLockedUntil).toLocaleTimeString('zh-CN', {
      hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
    }) : '';
    return `<section class="card stack">
      ${heading('lock', '验证家长身份', ui)}
      <p>输入演示 PIN <strong>2468</strong>，查看${ui.esc(state.childName)}的待办和账本。</p>
      <form class="form" data-action="parent-unlock">
        <label class="field">家长 PIN<input name="pin" type="password" inputmode="numeric" pattern="[0-9]{4}" minlength="4" maxlength="4" autocomplete="off" required></label>
        ${locked ? `<p class="muted" role="status">尝试次数已达上限，请在 ${ui.esc(retry)} 后重试。</p>` : ''}
        <div class="actions"><button type="submit" class="primary">进入家长控制台</button></div>
      </form>
    </section>`;
  }

  function questionSection(questions, ui) {
    const pending = questions.filter((question) => !question.confirmed);
    const forms = pending.map((question) => `<form class="item form" data-action="question-confirm">
      <input type="hidden" name="id" value="${ui.esc(question.id)}">
      <div><span class="badge">${ui.esc(question.subject)}</span><p><strong>${ui.esc(question.prompt)}</strong></p></div>
      <label class="field">标准答案<input name="answer" value="${ui.esc(question.answer)}" maxlength="500" required></label>
      <div class="actions"><button type="submit" class="primary">确认标准答案</button></div>
    </form>`).join('');
    return `<section class="card stack">
      ${heading('pencil', '错题答案确认', ui)}
      ${forms ? `<p class="muted">请核对孩子录入的题目。家长确认标准答案后，题目才可进入奖励复习。</p>${forms}` : '<p class="muted">当前没有待确认的错题。</p>'}
    </section>`;
  }

  function requestItem(request, ui) {
    const id = ui.esc(request.id);
    let action = '';
    let note = '';
    switch (request.status) {
      case 'requested':
        note = '申请已冻结金币。拒绝后，金币退回可用余额。';
        action = `<button class="primary" type="button" data-action="request-approve" data-id="${id}">批准申请</button>
          <button class="secondary" type="button" data-action="request-reject" data-id="${id}">拒绝并退回金币</button>`;
        break;
      case 'approved':
        note = '请先兑现奖励，再确认履约并结清冻结金币。';
        action = `<button class="primary" type="button" data-action="request-fulfill" data-id="${id}">确认已履约</button>`;
        break;
      case 'fulfilled':
        note = '已从冻结金币中结清。';
        break;
      case 'rejected':
        note = '已将冻结金币退回可用余额。';
        break;
    }
    return `<article class="item stack">
      <div class="row"><strong>${ui.esc(request.title)}</strong><span class="badge">${ui.esc(requestStatus[request.status])}</span></div>
      <p class="muted">${ui.esc(request.cost)} 金币 · ${note}</p>
      ${action ? `<div class="actions">${action}</div>` : ''}
    </article>`;
  }

  function rewardSection(requests, ui) {
    const open = requests.filter((request) => ['requested', 'approved'].includes(request.status));
    const closed = requests.filter((request) => ['rejected', 'fulfilled'].includes(request.status));
    return `<section class="card stack">
      ${heading('gift', '奖励审批与履约', ui)}
      ${open.length ? open.map((request) => requestItem(request, ui)).join('') : '<p class="muted">当前没有待审批或待履约的申请。</p>'}
      ${closed.length ? `<details><summary>已处理的申请（${ui.esc(closed.length)}）</summary><div class="stack">${closed.map((request) => requestItem(request, ui)).join('')}</div></details>` : ''}
    </section>`;
  }

  function taskSection(ui) {
    return `<section class="card stack">
      ${heading('clock', '创建学习任务', ui)}
      <form class="form" data-action="task-create">
        <label class="field">任务名称<input name="title" placeholder="例如：课后阅读" maxlength="60" required></label>
        <label class="field">目标时长（分钟）<input name="minutes" type="number" inputmode="numeric" min="1" max="240" step="1" value="20" required></label>
        <label class="field">重复规则<select name="repeat"><option value="mwf">每周一、三、五</option><option value="once">仅一次</option></select></label>
        <div class="actions"><button class="primary" type="submit">发布任务</button><button class="quiet" type="button" data-view="tasks">查看任务中心</button></div>
      </form>
    </section>`;
  }

  function ledgerSection(state, ui) {
    const metrics = [['可用金币', state.coins], ['冻结金币', state.frozen], ['成长 XP', state.xp]];
    const rows = state.ledger.map((entry) => {
      const changes = [['可用金币', entry.coins], ['冻结金币', entry.frozen], ['XP', entry.xp]]
        .filter(([, amount]) => amount !== 0)
        .map(([label, amount]) => `${label} ${amount > 0 ? '+' : ''}${ui.esc(amount)}`);
      return `<div class="item"><strong>${ui.esc(entry.label)}</strong><p class="muted">${changes.join(' · ') || '本笔余额无变动'}</p></div>`;
    }).join('');
    return `<section class="card stack">
      ${heading('receipt', '金币与 XP 账本', ui)}
      <div class="metrics">${metrics.map(([label, value]) => `<div class="metric"><strong>${ui.esc(value)}</strong><span>${label}</span></div>`).join('')}</div>
      ${rows ? `<details open><summary>查看每笔来源与变动</summary><div class="stack">${rows}</div></details>` : '<p class="muted">尚无账本流水。</p>'}
    </section>`;
  }

  function render(view, state, ui) {
    if (view !== 'parent') return '';
    if (!state.parentUnlocked) return pinForm(state, ui);
    return `<div class="stack">
      <div class="row"><strong>${ui.esc(state.childName)}的家庭学习记录</strong><button class="quiet" type="button" data-action="parent-lock">退出家长模式</button></div>
      <div class="grid">${questionSection(state.questions, ui)}${rewardSection(state.requests, ui)}</div>
      ${taskSection(ui)}${ledgerSection(state, ui)}
      <section class="card"><h2>演示数据</h2><p class="muted">重置会清除当前浏览器中这个演示家庭的操作记录，恢复初始任务、金币和 XP。</p><button type="button" class="quiet" data-action="demo-reset">重置演示数据</button></section>
    </div>`;
  }

  window.PlanetDemoParent = { render };
})();
