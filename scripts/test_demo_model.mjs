import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const script = readFileSync(new URL('../docs/demo/model.js', import.meta.url), 'utf8');

function example() {
  const memory = {};
  let now = Date.UTC(2026, 0, 1);
  function open() {
    const window = {};
    class Clock extends Date { static now() { return now; } }
    runInNewContext(script, { window, Date: Clock });
    const store = window.PlanetDemoModel.create(memory);
    return { act: store.act, read: () => structuredClone(store.read()) };
  }
  return { open, advance: ms => { now += ms; } };
}
const unlock = store => store.act('parent-unlock', { pin: '2468' });

test('only confirmed questions enter the ten-item queue; start freezes content and grading pays once', () => {
  const demo = example();
  const store = demo.open();
  const initial = store.read();
  const draft = initial.questions.find(question => !question.confirmed);
  const confirm = id => store.act('question-confirm', { id, answer: '7' });
  assert.throws(() => confirm(draft.id), /家长/);
  unlock(store);
  assert.throws(() => store.act('question-confirm', { id: draft.id, answer: '甲'.repeat(501) }), /500/);
  for (let i = 0; i < 8; i++) {
    store.act('question-add', { subject: '数学', prompt: '练习 ' + i, answer: '7' });
    confirm(store.read().questions.at(-1).id);
  }
  assert.equal(store.read().review.backlog, 1);
  assert.equal(store.read().coins, initial.coins);
  store.act('review-start');
  const items = store.read().review.items;
  assert.equal(items.length, 10);
  confirm(draft.id);
  assert.deepEqual(store.read().review.items, items);
  assert.equal(store.read().review.backlog, 2);
  const grade = (id, answer) => store.act('review-answer', { id, answer, confidence: '很有把握' });
  assert.throws(() => grade(draft.id, '7'));
  items.forEach((question, index) => {
    const answer = index < 2 ? question.answer : '错误答案';
    grade(question.id, answer);
    grade(question.id, answer);
    if (index < items.length - 1) assert.equal(store.read().xp, initial.xp);
  });
  assert.throws(() => grade(items[0].id, '换一个答案'));
  const done = demo.open().read();
  assert.equal(done.review.status, 'done');
  assert.equal(done.review.answers.length, 10);
  assert.deepEqual(done.review.settlement, { coins: 30, xp: 30 });
  assert.equal(done.coins, initial.coins + 30);
  assert.equal(done.xp, initial.xp + 30);
  assert.equal(done.ledger.length, initial.ledger.length + 1);
});

test('Monday/Wednesday/Friday reading requires a parent; completing two tasks counts one learning day', () => {
  const store = example().open();
  const initial = store.read();
  const reading = { title: '课后阅读', minutes: '20', repeat: 'mwf' };
  assert.throws(() => store.act('task-create', reading), /家长/);
  unlock(store);
  assert.throws(() => store.act('task-create', { ...reading, minutes: 241 }), /240/);
  assert.throws(() => store.act('task-create', { ...reading, title: '甲'.repeat(61) }), /60/);
  store.act('task-create', reading);
  const task = store.read().tasks.at(-1);
  assert.deepEqual(task.weekdays, [1, 3, 5]);
  assert.equal(task.minutes, 20);
  for (const id of [task.id, initial.tasks[0].id]) {
    store.act('task-start', { id });
    store.act('task-pause', { id });
    assert.throws(() => store.act('task-complete', { id }));
    store.act('task-resume', { id });
    store.act('task-complete', { id });
    store.act('task-complete', { id });
  }
  assert.equal(store.read().coins, initial.coins + 50);
  assert.equal(store.read().xp, initial.xp + 40);
  assert.equal(store.read().streakDays, initial.streakDays + 1);
});

test('redeeming reserves available coins; rejection releases them and fulfillment settles once across tabs', () => {
  const demo = example();
  const child = demo.open();
  const parent = demo.open();
  const initial = child.read();
  const reward = initial.rewards[0];
  const buy = key => child.act('reward-request', { id: reward.id, requestKey: key });
  const balances = () => [child.read().coins, child.read().frozen];
  buy('first');
  buy('first');
  buy('while-pending');
  assert.equal(parent.read().requests.length, 1);
  const first = parent.read().requests[0];
  assert.deepEqual(balances(), [initial.coins - reward.cost, reward.cost]);
  assert.throws(() => parent.act('request-reject', first), /家长/);
  unlock(parent);
  parent.act('request-reject', first);
  parent.act('request-reject', first);
  buy('while-pending');
  assert.deepEqual(balances(), [initial.coins, 0]);
  assert.equal(parent.read().requests.length, 1);
  buy('new-request');
  const second = parent.read().requests[0];
  assert.throws(() => parent.act('request-fulfill', second));
  parent.act('request-approve', second);
  assert.deepEqual(balances(), [initial.coins - reward.cost, reward.cost]);
  parent.act('request-fulfill', second);
  parent.act('request-fulfill', second);
  buy('new-request');
  assert.deepEqual(balances(), [initial.coins - reward.cost, 0]);
  assert.equal(parent.read().ledger.length, initial.ledger.length + 4);
});

test('the five-attempt PIN lock survives reload; only a verified parent can reset this example', () => {
  const demo = example();
  const one = demo.open();
  const two = demo.open();
  assert.throws(() => one.act('demo-reset'));
  for (let i = 0; i < 5; i++) assert.throws(() => one.act('parent-unlock', { pin: '0000' }));
  demo.advance(599999);
  assert.throws(() => unlock(demo.open()), /锁定/);
  demo.advance(1);
  unlock(one);
  unlock(two);
  assert.equal(demo.open().read().parentUnlocked, false);
  one.act('question-add', { subject: '语文', prompt: '新增题', answer: '甲' });
  one.act('demo-reset');
  assert.equal(one.read().parentUnlocked, false);
  assert.equal(two.read().parentUnlocked, false);
  assert.equal(two.read().questions.some(question => question.prompt === '新增题'), false);
});

test('opening on an opaque origin supports in-tab actions when persistence is unavailable', async () => {
  const window = {};
  for (const key of ['indexedDB', 'localStorage']) {
    Object.defineProperty(window, key, { get() { throw new DOMException('Denied', 'SecurityError'); } });
  }
  runInNewContext(script, { window });
  const store = await window.PlanetDemoModel.openBrowser();
  const initial = store.read();
  assert.equal(initial.storageAvailable, false);
  const id = initial.tasks[0].id;
  store.act('task-start', { id });
  store.act('task-complete', { id });
  assert.equal(store.read().coins, initial.coins + initial.tasks[0].rewardCoins);
  assert.equal((await window.PlanetDemoModel.openBrowser()).read().tasks[0].status, 'ready');
});

// A small transaction boundary fixture: snapshots are structured clones and a
// failed transaction discards the staged record, as native IndexedDB does.
function indexedFixture() {
  let record, tail = Promise.resolve(), failNextCommit;
  const database = {
    close() {},
    transaction(store, mode) {
      assert.equal(store, 'records');
      const tx = {};
      const request = {};
      let staged, aborted = false;
      tx.abort = () => { aborted = true; };
      tx.objectStore = () => ({
        get(key) { assert.equal(key, 'family'); return request; },
        put(value, key) {
          assert.equal(mode, 'readwrite');
          assert.equal(key, 'family');
          staged = structuredClone(value);
        },
      });
      tail = tail.then(() => {
        request.result = structuredClone(record);
        request.onsuccess();
        if (staged && failNextCommit) {
          tx.error = new DOMException('Injected storage failure', failNextCommit);
          failNextCommit = null;
          aborted = true;
        }
        if (aborted) tx.onabort();
        else {
          if (staged) record = staged;
          tx.oncomplete();
        }
      });
      return tx;
    },
  };
  const indexedDB = { open() {
    const request = { result: database };
    queueMicrotask(() => request.onsuccess());
    return request;
  } };
  function tab(onCommit = () => {}) {
    const window = { indexedDB };
    runInNewContext(script, { window });
    return window.PlanetDemoModel.openBrowser(onCommit);
  }
  return { tab, fail: name => { failNextCommit = name; } };
}

test('two durable sessions apply distinct simultaneous task rewards to the latest transaction state', async () => {
  const db = indexedFixture();
  const revisions = [];
  const [one, two] = await Promise.all([db.tab(r => revisions.push(r)), db.tab(r => revisions.push(r))]);
  const [reading, bag] = one.read().tasks;
  await Promise.all([one.act('task-start', reading), two.act('task-start', bag)]);
  await Promise.all([one.act('task-complete', reading), two.act('task-complete', bag)]);
  const reopened = (await db.tab()).read();
  assert.equal(reopened.coins, 195);
  assert.equal(reopened.xp, 108);
  assert.equal(reopened.ledger.length, 3);
  assert.deepEqual(revisions, [1, 2, 3, 4]);
  await Promise.all([one.refresh(), two.refresh()]);
  assert.equal(one.read().coins, reopened.coins);
  assert.equal(two.read().coins, reopened.coins);
});

test('a failed commit does not grant authorization or acknowledge a reward; revoked storage can continue locally', async () => {
  const db = indexedFixture();
  const published = [];
  const store = await db.tab(r => published.push(r));
  db.fail('QuotaExceededError');
  await assert.rejects(store.act('parent-unlock', { pin: '2468' }), /本次操作没有生效/);
  assert.equal(store.read().parentUnlocked, false);
  const task = store.read().tasks[0];
  await store.act('task-start', task);
  db.fail('SecurityError');
  await assert.rejects(store.act('task-complete', task), /本次操作没有生效/);
  assert.equal(store.read().storageAvailable, false);
  assert.equal(store.read().coins, 160);
  assert.equal((await db.tab()).read().tasks[0].status, 'active');
  assert.match(await store.act('task-complete', task), /完成/);
  assert.equal(store.read().coins, 185);
  assert.equal((await db.tab()).read().coins, 160);
  assert.deepEqual(published, [1]);
});

test('transaction-time authorization and generation checks reject actions queued before reset', async () => {
  const db = indexedFixture();
  const [one, two] = await Promise.all([db.tab(), db.tab()]);
  await one.act('parent-unlock', { pin: '2468' });
  await two.act('parent-unlock', { pin: '2468' });
  const generation = two.read().generation;
  const reset = one.act('demo-reset');
  const stale = two.act('task-create', { title: '过期操作', minutes: 10, repeat: 'once' }, { generation });
  await reset;
  await assert.rejects(stale, /已重置/);
  await two.refresh();
  assert.equal(two.read().parentUnlocked, false);
  assert.equal(two.read().tasks.length, 2);
});
