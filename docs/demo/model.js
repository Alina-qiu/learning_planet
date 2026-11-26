(function () {
  'use strict';

  const storageKey = 'learning-planet.demo.v1';
  const subjects = ['数学', '语文', '英语'];
  const confidences = ['不确定', '比较有把握', '很有把握'];
  const initialQuestions = [
    { id: 'q-math', subject: '数学', prompt: '有 24 支彩笔，平均装进 4 个盒子。每个盒子里有几支？请填写数字。', answer: '6' },
    { id: 'q-chinese', subject: '语文', prompt: '“春眠不觉晓，处处闻啼鸟。”句中哪个字表示“早晨”？', answer: '晓' },
    { id: 'q-english', subject: '英语', prompt: '根据提示补全并写出整个英文单词：c_t（猫）。', answer: 'cat' },
  ];

  const copy = value => JSON.parse(JSON.stringify(value));

  function refreshItems(state) {
    const due = state.questions.filter(question => question.confirmed && question.due);
    if (state.review.status === 'ready') {
      const confidenceRank = q => q.lastConfidence ? confidences.indexOf(q.lastConfidence) : confidences.length;
      due.sort((a, b) => b.overdueDays - a.overdueDays || b.wrongCount - a.wrongCount ||
        confidenceRank(a) - confidenceRank(b));
      state.review.items = due.slice(0, 10).map(({ id, subject, prompt, answer }) => ({ id, subject, prompt, answer }));
    }
    const selected = new Set(state.review.items.map(item => item.id));
    state.review.backlog = due.filter(question => !selected.has(question.id)).length;
  }

  function initialRecord() {
    const state = {
      childName: '小星', coins: 160, xp: 80, frozen: 0, streakDays: 1,
      tasks: [
        { id: 't-reading', title: '阅读 20 分钟', minutes: 20, rewardCoins: 25, rewardXp: 20, status: 'ready', repeat: 'once' },
        { id: 't-bag', title: '整理明天的书包', minutes: 5, rewardCoins: 10, rewardXp: 8, status: 'ready', repeat: 'once' },
      ],
      questions: [
        ...initialQuestions.map((question, index) => ({ ...question, confirmed: true, due: true,
          overdueDays: index === 0 ? 1 : 0, wrongCount: index === 1 ? 2 : 1, lastConfidence: null })),
        { id: 'q-draft', subject: '数学', prompt: '一周有几天？', answer: '7', confirmed: false, due: false,
          overdueDays: 0, wrongCount: 0, lastConfidence: null },
      ],
      review: { status: 'ready', items: [], answers: [], backlog: 0, settlement: { coins: 0, xp: 0 } },
      rewards: [
        { id: 'r-cartoon', title: '看 30 分钟动画片', cost: 120 },
        { id: 'r-game', title: '周末游戏 30 分钟', cost: 220 },
        { id: 'r-book', title: '选择一本新书', cost: 500 },
      ],
      requests: [],
      ledger: [{ label: '示例期初余额', coins: 160, xp: 80, frozen: 0 }],
      pinAttempts: 0, pinLockedUntil: 0,
    };
    refreshItems(state);
    return { version: 1, generation: 0, sequence: 1, state, requestKeys: [] };
  }

  function text(value, label, limit) {
    if (typeof value !== 'string' || !value.trim() || value.trim().length > limit) {
      throw new Error('请填写' + label + '，最多 ' + limit + ' 个字。');
    }
    return value.trim();
  }

  function normalized(value) {
    return value.normalize('NFC').trim().replace(/\s+/g, ' ').toLowerCase();
  }

  function find(rows, id, label) {
    const row = rows.find(item => item.id === id);
    if (!row) throw new Error('找不到这' + label + '，请重新打开。');
    return row;
  }

  function nextId(record, prefix) {
    return prefix + '-' + record.sequence++;
  }

  function post(state, label, coins, xp, frozen) {
    state.coins += coins;
    state.xp += xp;
    state.frozen += frozen;
    state.ledger.unshift({ label, coins, xp, frozen });
  }

  // This fixed demo day follows one completed learning day.
  function completeToday(state) {
    state.streakDays = 2;
  }

  function taskAction(state, action, id) {
    const task = find(state.tasks, id, '个任务');
    const [from, to, message] = {
      'task-start': ['ready', 'active', '任务已开始。'],
      'task-pause': ['active', 'paused', '任务已暂停。'],
      'task-resume': ['paused', 'active', '任务已继续。'],
      'task-complete': ['active', 'done', '任务已完成，奖励已入账。'],
    }[action];
    if (task.status === to) return '这项任务已经处理过了。';
    if (task.status !== from) throw new Error('当前任务状态不支持这个操作。');
    task.status = to;
    if (action === 'task-complete') {
      post(state, '完成任务 · ' + task.title, task.rewardCoins, task.rewardXp, 0);
      completeToday(state);
    }
    return message;
  }

  function answerReview(state, payload) {
    const review = state.review;
    if (review.status === 'ready') throw new Error('请先开始今日复习。');
    const item = find(review.items, payload.id, '道复习题');
    const submitted = text(payload.answer, '你的答案', 500);
    if (!confidences.includes(payload.confidence)) throw new Error('请选择这次作答的把握程度。');
    const existing = review.answers.find(answer => answer.questionId === item.id);
    if (existing) {
      if (normalized(existing.submitted) !== normalized(submitted) || existing.confidence !== payload.confidence) {
        throw new Error('这道题已提交，本次作答已保存。');
      }
      return '这道题已经提交。';
    }
    if (review.status !== 'active') throw new Error('本次复习已经结束。');
    const correct = normalized(submitted) === normalized(item.answer);
    review.answers.push({ questionId: item.id, submitted, correct, confidence: payload.confidence });
    if (review.answers.length < review.items.length) {
      return correct ? '答对了，继续下一题。' : '已记录这次作答，下次继续练习。';
    }
    review.status = 'done';
    for (const result of review.answers) {
      const question = find(state.questions, result.questionId, '道错题');
      question.due = false;
      question.lastConfidence = result.confidence;
      if (result.correct) {
        review.settlement.coins += 15;
        review.settlement.xp += 15;
      } else {
        question.wrongCount++;
      }
    }
    if (review.settlement.coins || review.settlement.xp) {
      post(state, '今日错题复习', review.settlement.coins, review.settlement.xp, 0);
    }
    completeToday(state);
    refreshItems(state);
    return '今日复习已完成，共答对 ' + review.answers.filter(result => result.correct).length + ' 题。';
  }

  function requestReward(record, payload) {
    const state = record.state;
    const reward = find(state.rewards, payload.id, '个奖励');
    const key = payload.requestKey == null ? null : text(payload.requestKey, '申请标识', 128);
    const receipt = key && record.requestKeys.find(entry => entry.key === key);
    if (receipt) {
      const previous = find(state.requests, receipt.requestId, '个申请');
      if (previous.rewardId !== reward.id) throw new Error('这次申请标识已用于另一项奖励，请重新申请。');
      return '这次兑换申请已记录，可在兑换记录查看。';
    }
    let request = state.requests.find(row => row.rewardId === reward.id &&
      (row.status === 'requested' || row.status === 'approved'));
    let message = '演示中，同一奖励同时保留一份待处理申请。';
    if (!request) {
      if (state.coins < reward.cost) throw new Error('可用金币还差 ' + (reward.cost - state.coins) + ' 枚。');
      request = { id: nextId(record, 'request'), rewardId: reward.id, title: reward.title,
        cost: reward.cost, status: 'requested' };
      state.requests.unshift(request);
      post(state, '兑换申请 · ' + reward.title, -reward.cost, 0, reward.cost);
      message = '已申请兑换，' + reward.cost + ' 金币已冻结，等待家长处理。';
    }
    if (key) record.requestKeys.push({ key, requestId: request.id });
    return message;
  }

  function decideRequest(state, name, id) {
    const request = find(state.requests, id, '个兑换申请');
    const [from, to] = {
      'request-approve': ['requested', 'approved'],
      'request-reject': ['requested', 'rejected'],
      'request-fulfill': ['approved', 'fulfilled'],
    }[name];
    if (request.status === to) return '这份兑换申请已经处理过了。';
    if (request.status !== from) throw new Error('当前申请状态不能执行这个操作。');
    request.status = to;
    if (to === 'approved') return '已批准，奖励兑现后请确认履约。';
    if (to === 'rejected') {
      post(state, '退回兑换 · ' + request.title, request.cost, 0, -request.cost);
      return '已拒绝，冻结金币已退回可用余额。';
    }
    post(state, '兑换履约 · ' + request.title, 0, 0, -request.cost);
    return '已确认履约，冻结金币已结算。';
  }

  function apply(record, name, payload, parent) {
    const state = record.state;
    if (['task-create', 'question-confirm', 'request-approve', 'request-reject', 'request-fulfill'].includes(name) && !parent) {
      throw new Error('请先进入家长模式并验证演示 PIN。');
    }
    switch (name) {
      case 'task-start': case 'task-pause': case 'task-resume': case 'task-complete':
        return taskAction(state, name, payload.id);
      case 'task-create': {
        const title = text(payload.title, '任务名称', 60);
        const minutes = Number(payload.minutes);
        if (!['number', 'string'].includes(typeof payload.minutes) || !Number.isInteger(minutes) ||
            minutes < 1 || minutes > 240) throw new Error('预计时长请填写 1 至 240 的整数分钟。');
        if (!['once', 'mwf'].includes(payload.repeat)) throw new Error('请选择任务频率。');
        const task = { id: nextId(record, 'task'), title, minutes, rewardCoins: minutes >= 20 ? 25 : 15,
          rewardXp: minutes >= 20 ? 20 : 12, repeat: payload.repeat, status: 'ready' };
        if (task.repeat === 'mwf') task.weekdays = [1, 3, 5];
        state.tasks.push(task);
        return '已创建任务“' + title + '”。';
      }
      case 'question-add': {
        if (!subjects.includes(payload.subject)) throw new Error('请选择学科。');
        const prompt = text(payload.prompt, '题目', 500);
        const answer = text(payload.answer, '参考答案', 500);
        state.questions.push({ id: nextId(record, 'question'), subject: payload.subject, prompt,
          answer, confirmed: false, due: false, overdueDays: 0, wrongCount: 0, lastConfidence: null });
        return '已收进错题本，等待家长确认标准答案。';
      }
      case 'question-confirm': {
        const question = find(state.questions, payload.id, '道错题');
        const answer = text(payload.answer, '标准答案', 500);
        if (question.confirmed) {
          if (question.answer === answer) return '标准答案已确认。';
          throw new Error('这道题的标准答案已经确认。');
        }
        Object.assign(question, { answer, confirmed: true, due: true });
        refreshItems(state);
        return state.review.status === 'ready' ? '标准答案已确认，今日待复习题单已更新。' :
          '标准答案已确认，留待后续复习，本次题单已固定。';
      }
      case 'review-start':
        if (state.review.status === 'done') throw new Error('今日复习已完成，可查看记录。');
        if (state.review.status === 'active') return '可以继续本次复习。';
        refreshItems(state);
        if (!state.review.items.length) throw new Error('今天暂无到期复习题。');
        state.review.status = 'active';
        return '今日复习已开始，本次题单已固定。';
      case 'review-answer': return answerReview(state, payload);
      case 'reward-request': return requestReward(record, payload);
      case 'request-approve': case 'request-reject': case 'request-fulfill':
        return decideRequest(state, name, payload.id);
      default: throw new Error('无法识别这个操作。');
    }
  }

  function decode(raw) {
    try {
      const record = JSON.parse(raw);
      const state = record.state;
      const rows = array => Array.isArray(array) && array.every(row => row && typeof row === 'object');
      const amount = value => Number.isSafeInteger(value) && value >= 0;
      if (record.version !== 1 || !Number.isSafeInteger(record.sequence) || record.sequence < 1 ||
          !rows(record.requestKeys) || !state || typeof state.childName !== 'string' ||
          !['coins', 'xp', 'frozen', 'pinAttempts', 'pinLockedUntil'].every(key => amount(state[key])) ||
          !['tasks', 'questions', 'rewards', 'requests', 'ledger'].every(key => rows(state[key])) ||
          !['ready', 'active', 'done'].includes(state.review.status) ||
          !rows(state.review.items) || !rows(state.review.answers)) return initialRecord();

      // Complete older examples from their own submitted answers and task history.
      if (record.generation === undefined) record.generation = 0;
      if (state.streakDays === undefined) {
        state.streakDays = state.review.status === 'done' || state.tasks.some(task => task.status === 'done') ? 2 : 1;
      }
      if (state.review.settlement === undefined) {
        const total = state.review.status === 'done' ? 15 * state.review.answers.filter(answer => answer.correct).length : 0;
        state.review.settlement = { coins: total, xp: total };
      }
      for (const question of state.questions) {
        if (question.overdueDays === undefined) question.overdueDays = question.id === 'q-math' ? 1 : 0;
        if (question.wrongCount === undefined) question.wrongCount = question.id === 'q-chinese' ? 2 : 0;
        if (question.lastConfidence === undefined) question.lastConfidence = null;
      }
      if (state.review.backlog === undefined) refreshItems(state);
      if (amount(record.generation) && amount(state.streakDays) && amount(state.review.backlog) &&
          amount(state.review.settlement.coins) && amount(state.review.settlement.xp)) return record;
    } catch (_) { /* Missing or invalid demo data starts a new example. */ }
    return initialRecord();
  }

  function currentLock(state) {
    return state.pinLockedUntil > Date.now() ? state.pinLockedUntil : 0;
  }

  function transition(record, name, payload, authorized) {
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new Error('操作内容无效，请重新填写。');
    let next = copy(record);
    let message, error, access;
    if (next.state.pinLockedUntil && !currentLock(next.state)) {
      next.state.pinAttempts = 0;
      next.state.pinLockedUntil = 0;
    }
    if (name === 'demo-reset') {
      if (!authorized) throw new Error('请先进入家长模式，再重置演示。');
      next = initialRecord();
      next.generation = record.generation + 1;
      access = false;
      message = '已恢复初始示例，当前为孩子模式。';
    } else if (name === 'parent-unlock') {
      if (currentLock(next.state)) throw new Error('演示 PIN 已锁定，请稍后再试。');
      access = payload.pin === '2468';
      if (access) {
        next.state.pinAttempts = 0;
        message = '已进入家长模式。';
      } else {
        const remaining = 5 - ++next.state.pinAttempts;
        if (remaining === 0) next.state.pinLockedUntil = Date.now() + 600000;
        error = remaining ? 'PIN 不正确，还可以尝试 ' + remaining + ' 次。' : '连续 5 次验证失败，已锁定 10 分钟。';
      }
    } else {
      message = apply(next, name, payload, authorized);
    }
    next.revision = (record.revision || 0) + 1;
    return { record: next, access, message, error };
  }

  function session(initial, source) {
    let record = initial, unlocked = false, accessEpoch = 0;
    function lock() { unlocked = false; accessEpoch++; }
    function adopt(next) {
      if ((next.revision || 0) < (record.revision || 0)) return false;
      if (next.generation !== record.generation || currentLock(next.state)) lock();
      const changed = next.revision !== record.revision;
      record = next;
      return changed;
    }
    function read() {
      if (source.peek) adopt(source.peek());
      const state = copy(record.state);
      if (state.pinLockedUntil && !currentLock(state)) {
        state.pinAttempts = 0;
        state.pinLockedUntil = 0;
      }
      return { ...state, parentUnlocked: unlocked, generation: record.generation, storageAvailable: source.persistent };
    }
    function act(name, payload = {}, guard = {}) {
      if (name === 'parent-lock') { lock(); return '已返回孩子模式。'; }
      const epoch = accessEpoch;
      return source.update(latest => {
        if (guard.current && !guard.current()) return null;
        if (guard.generation !== undefined && guard.generation !== latest.generation) {
          throw new Error('示例家庭已重置，请核对新页面后再操作。');
        }
        const authorized = unlocked && epoch === accessEpoch && record.generation === latest.generation && !currentLock(latest.state);
        return transition(latest, name, payload, authorized);
      }, result => {
        if (!result) return;
        const stillCurrent = epoch === accessEpoch && (!guard.current || guard.current());
        adopt(result.record);
        if (result.access === false) lock();
        if (result.access === true && stillCurrent && record.generation === result.record.generation && !currentLock(record.state)) unlocked = true;
        if (result.error) throw new Error(result.error);
        return result.message;
      });
    }
    return Object.freeze({ read, act, refresh: () => source.refresh(adopt) });
  }

  // Either one local session or several synchronous rule tests can use this
  // in-memory record. Production browser persistence uses the transaction below.
  function memorySource(memory) {
    memory.record ??= initialRecord();
    return {
      persistent: false,
      peek: () => memory.record,
      refresh: adopt => adopt(memory.record),
      update(change, finish) {
        const result = change(memory.record);
        if (result) memory.record = result.record;
        return finish(result);
      },
    };
  }

  function create(memory = {}) {
    const source = memorySource(memory);
    return session(memory.record, source);
  }

  function transaction(db, mode, work) {
    return new Promise((resolve, reject) => {
      const tx = db.transaction('records', mode);
      const records = tx.objectStore('records');
      let result, cause;
      tx.oncomplete = () => resolve(result);
      tx.onabort = () => reject(cause || tx.error || new Error('浏览器保存事务已中止，本次操作没有生效。'));
      const request = records.get('family');
      request.onsuccess = () => {
        try { result = work(request.result, records); }
        catch (error) { cause = error; tx.abort(); }
      };
    });
  }

  async function openBrowser(onCommit = () => {}) {
    let db, initial;
    try {
      db = await new Promise((resolve, reject) => {
        const request = window.indexedDB.open(storageKey, 1);
        request.onupgradeneeded = () => request.result.createObjectStore('records');
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
      initial = await transaction(db, 'readwrite', (existing, records) => {
        if (existing) return existing;
        // Import the previous prototype only when this database is first opened.
        let legacy;
        try { legacy = window.localStorage.getItem(storageKey); } catch (_) { /* Optional. */ }
        const record = legacy ? decode(legacy) : initialRecord();
        record.revision = 0;
        records.put(record, 'family');
        return record;
      });
    } catch (_) {
      db?.close();
      return create();
    }
    db.onversionchange = () => db.close();
    let lastCommitted = initial;
    function remember(record) {
      if ((record.revision || 0) >= (lastCommitted.revision || 0)) lastCommitted = record;
      return record;
    }
    function denyStorage(error) {
      if (error.name !== 'SecurityError' && error.name !== 'NotAllowedError') return false;
      if (source.persistent) {
        db.close();
        Object.assign(source, memorySource({ record: lastCommitted }));
      }
      return true;
    }
    const source = {
      persistent: true,
      async refresh(adopt) {
        try { return adopt(remember(await transaction(db, 'readonly', record => record))); }
        catch (error) { if (denyStorage(error)) return true; throw error; }
      },
      async update(change, finish) {
        let result;
        try {
          result = await transaction(db, 'readwrite', (latest, records) => {
            const next = change(latest);
            if (next) records.put(next.record, 'family');
            return next;
          });
        } catch (error) {
          if (denyStorage(error)) {
            throw new Error('浏览器已拒绝存储，本次操作没有生效。可在当前标签页重新操作，关闭后不会保留。');
          }
          if (['QuotaExceededError', 'InvalidStateError', 'AbortError', 'UnknownError'].includes(error.name)) {
            throw new Error('浏览器未能保存，本次操作没有生效。请检查存储权限或空间后重试。');
          }
          throw error;
        }
        if (result) {
          remember(result.record);
          try { onCommit(result.record.revision); } catch (_) { /* Already committed. */ }
        }
        return finish(result);
      },
    };
    return session(initial, source);
  }

  window.PlanetDemoModel = Object.freeze({ create, openBrowser, storageKey });
})();
