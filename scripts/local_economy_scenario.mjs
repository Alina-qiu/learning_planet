// Public-API setup and read-only evidence for an actual APK reward walkthrough.
// Only setup/price mutate server fixtures; requesting and fulfilling use the UI.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {realApiClient} from './fixtures/real_api_client.mjs';

const phase = process.argv[2];
assert.ok(['setup', 'requested', 'fulfilled', 'price', 'reconnected'].includes(phase),
  'Usage: local_economy_scenario.mjs setup|requested|fulfilled|price|reconnected');
const directory = '.dart_tool/local-backend';
const control = JSON.parse(await readFile(`${directory}/control.json`, 'utf8'));
const config = JSON.parse(await readFile(`${directory}/defines.json`, 'utf8'));
assert.equal(control.url, 'http://127.0.0.1:54321');
const health = await fetch(`${control.url}/__local/health`, {signal: AbortSignal.timeout(3000)});
assert.equal(health.status, 200);
assert.equal((await health.json()).runId, control.runId);
const api = realApiClient({url: control.mailUrl, anon: config.SUPABASE_ANON_KEY, mailboxKey: control.mailboxKey});
const path = `${directory}/economy-scenario.json`;
let scenario;
if (phase === 'setup') {
  const user = await api.account(), family = await api.family(user);
  await api.rpc('adjust_wallet', user.token, {target_child_id: family.child, coins: 300,
    xp_amount: 0, reason: '本机奖励流程验证', command_id: randomUUID()});
  const reward = await api.rpc('save_reward', user.token, {target_family_id: family.id,
    target_reward_id: null, config: {title: '家庭电影', cost: 120, rules: '周末一起观看', stock_total: 2}});
  scenario = {runId: control.runId, user, family, reward, createdAt: new Date().toISOString()};
} else {
  scenario = JSON.parse(await readFile(path, 'utf8'));
  assert.equal(scenario.runId, control.runId, 'Start a new scenario after restarting the backend');
}
const {user, family} = scenario;
async function page(section) {
  return api.rpc('economy_page', user.token, {target_child_id: family.child, target_family_id: family.id,
    section, page_size: 50, after_created_at: null, after_id: null, include_inactive: false});
}
if (phase === 'price') {
  assert.equal((await api.rpc('verify_parent_pin', user.token,
    {target_family_id: family.id, candidate_pin: '2468'}))[0].verified, true);
  const reward = (await page('rewards')).items[0];
  assert.equal(reward.cost, 120);
  await api.rpc('save_reward', user.token, {target_family_id: family.id, target_reward_id: reward.id,
    config: {title: reward.title, cost: 140, rules: reward.rules, stock_total: 2, expected_version: reward.version}});
}
const overview = await api.rpc('wallet_overview', user.token, {target_child_id: family.child});
const [rewards, redemptions, ledger] = await Promise.all(['rewards', 'redemptions', 'ledger'].map(page));
assert.equal(rewards.items.length, 1);
assert.equal(overview.reconciled, true);
assert.equal(overview.xp, 0);
assert.equal(overview.coin_balance, phase === 'setup' ? 300 : 180);
assert.equal(overview.frozen_balance, phase === 'requested' ? 120 : 0);
assert.equal(rewards.items[0].cost, ['price', 'reconnected'].includes(phase) ? 140 : 120);
assert.equal(redemptions.items.length, phase === 'setup' ? 0 : 1);
if (phase !== 'setup') assert.equal(redemptions.items[0].status, phase === 'requested' ? 'requested' : 'fulfilled');
if (phase === 'fulfilled') scenario.fulfilledLedger = ledger.items.map(row => row.id).sort();
if (['price', 'reconnected'].includes(phase)) assert.deepEqual(ledger.items.map(row => row.id).sort(), scenario.fulfilledLedger);
await writeFile(path, JSON.stringify(scenario) + '\n', {mode: 0o600});
const evidence = {date: new Date().toISOString(), phase, runId: control.runId, email: user.email,
  child: family.child, overview, rewards: rewards.items, redemptions: redemptions.items, ledger: ledger.items};
await mkdir('build/local_economy_results', {recursive: true});
await writeFile(`build/local_economy_results/${phase}-${Date.now()}.json`, JSON.stringify(evidence, null, 2) + '\n');
console.log(JSON.stringify({phase, email: user.email, coins: overview.coin_balance, frozen: overview.frozen_balance,
  cost: rewards.items[0].cost, redemption: redemptions.items[0]?.status, ledgerEntries: ledger.items.length}));
