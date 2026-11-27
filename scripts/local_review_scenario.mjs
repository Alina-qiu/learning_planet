// Seed/inspect synthetic data for an actual APK offline-review walkthrough.
// This never submits answers, completes tasks, or changes the device's database.
import assert from 'node:assert/strict';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {realApiClient} from './fixtures/real_api_client.mjs';

const command=process.argv[2];
assert.ok(['setup','before-sync','after-sync'].includes(command),
  'Usage: local_review_scenario.mjs setup|before-sync|after-sync');
const directory='.dart_tool/local-backend';
const control=JSON.parse(await readFile(`${directory}/control.json`,'utf8'));
const config=JSON.parse(await readFile(`${directory}/defines.json`,'utf8'));
assert.equal(control.url,'http://127.0.0.1:54321');
const health=await fetch(`${control.url}/__local/health`,{signal:AbortSignal.timeout(3000)});
assert.equal(health.status,200);
assert.equal((await health.json()).runId,control.runId,'Start a new scenario after restarting the backend');
const api=realApiClient({url:control.mailUrl,anon:config.SUPABASE_ANON_KEY,mailboxKey:control.mailboxKey});
const path=`${directory}/review-scenario.json`;
let scenario;
if(command==='setup') {
  const user=await api.account();
  const family=await api.family(user);
  for(let i=1;i<=3;i++) {
    await api.rpc('save_review_question',user.token,{target_child_id:family.child,
      config:{kind:'question',subject:'math',prompt:`本机复习 ${i}：2+2=？`,answers:['4']},target_question_id:null});
  }
  const task=await api.rpc('generate_daily_wrong_review_task',user.token,{target_child_id:family.child});
  scenario={runId:control.runId,user,family,task,createdAt:new Date().toISOString()};
  await writeFile(path,JSON.stringify(scenario)+'\n',{mode:0o600});
} else {
  scenario=JSON.parse(await readFile(path,'utf8'));
  assert.equal(scenario.runId,control.runId,'Scenario belongs to a different disposable backend');
}
const snapshot=await api.rpc('load_review_task',scenario.user.token,{target_task_id:scenario.task});
assert.equal(snapshot.items.length,3);
const wallet=await api.api(`/rest/v1/wallets?select=coin_balance,frozen_balance,xp&child_id=eq.${scenario.family.child}`,scenario.user.token);
assert.equal(wallet.status,200);assert.equal(wallet.data.length,1);
const tasks=await api.api(`/rest/v1/task_instances?select=id,status&child_id=eq.${scenario.family.child}`,scenario.user.token);
assert.equal(tasks.status,200);assert.equal(tasks.data.length,1,'Only one daily task should exist');
const ledger=await api.api(`/rest/v1/ledger_entries?select=id,asset_type,amount,source_id&child_id=eq.${scenario.family.child}&order=asset_type`,scenario.user.token);
assert.equal(ledger.status,200);
const evidence={date:new Date().toISOString(),phase:command,runId:scenario.runId,email:scenario.user.email,
  task:snapshot.task.id,status:snapshot.task.status,wallet:wallet.data[0],items:snapshot.items.map(item=>({
    sequence:item.sequence,question:item.wrong_question_id,prompt:item.prompt,result:item.result,
    answer:item.answer_text,confidence:item.answer_confidence})),dailyTasks:tasks.data.length,ledger:ledger.data};
if(command==='setup'||command==='before-sync') {
  assert.equal(snapshot.task.status,'ready');
  assert.ok(snapshot.items.every(item=>item.result===null));
  assert.deepEqual(wallet.data[0],{coin_balance:0,frozen_balance:0,xp:0});
  assert.equal(ledger.data.length,0);
} else {
  assert.equal(snapshot.task.status,'completed');
  assert.deepEqual(snapshot.items.map(item=>item.result),[true,false,true]);
  assert.deepEqual(snapshot.items.map(item=>item.answer_confidence),[1,2,3]);
  assert.deepEqual(wallet.data[0],{coin_balance:30,frozen_balance:0,xp:30});
  assert.deepEqual(ledger.data.map(row=>[row.asset_type,row.amount,row.source_id]),
    [['coin',30,scenario.task],['xp',30,scenario.task]]);
}
await mkdir('build/local_review_results',{recursive:true});
await writeFile(`build/local_review_results/${command}-${Date.now()}.json`,JSON.stringify(evidence,null,2)+'\n');
console.log(JSON.stringify(evidence,null,2));
