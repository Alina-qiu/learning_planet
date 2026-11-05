import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';

export async function taskNoteCases({client,scalar,login,denied,check}) {
  const owner=randomUUID(), member=randomUUID(), stranger=randomUUID();
  await client.query('reset role');
  for(const [id,name] of [[owner,'owner'],[member,'member'],[stranger,'stranger']])
    await client.query('insert into auth.users values($1,$2)',[id,`notes-${name}@example.test`]);
  const auth=()=>login(owner,'task-notes'); await auth();
  await scalar("select public.onboard_family('Notes','Asia/Shanghai','Child',2::smallint)");
  const family=await scalar('select family_id from public.family_members where user_id=$1',[owner]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await client.query('reset role');
  await client.query("insert into public.family_members(family_id,user_id,role) values($1,$2,'parent')",[family,member]);
  const task=await scalar(`insert into public.task_instances(child_id,title,due_date,source_type,idempotency_key)
    values($1,'Read a book',current_date,'parent_template',$2) returning id`,[child,randomUUID()]);
  await auth();
  const read=()=>scalar('select public.task_note($1)',[task]);
  const sql='select public.resolve_task_note($1,$2,$3,$4)';
  const run=(text,id=randomUUID(),op='submit')=>scalar(sql,[task,id,text,op]);
  const original=randomUUID();
  await check('task notes work without PIN, share latest text and never modify task timing, versions or wallet',async()=>{
    const before=await scalar('select to_jsonb(t) from public.task_instances t where id=$1',[task]);
    const wallet=await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]);
    assert.equal((await read()).version,0);
    const first=await run('读到第三章，想讨论主人公的选择',original);
    assert.equal(first.status,'applied'); assert.equal(first.applied_version,1);
    assert.equal(first.current.child_id,child); assert.equal(first.current.family_id,family);
    await login(member,'note-member'); assert.equal((await read()).body,first.current.body);
    const second=await run('晚上一起讨论'); assert.equal(second.applied_version,2);
    await auth();
    const replay=await run('读到第三章，想讨论主人公的选择',original);
    assert.equal(replay.applied_version,1); assert.equal(replay.current.version,2);
    assert.equal(replay.current.body,'晚上一起讨论');
    assert.deepEqual(await scalar('select to_jsonb(t) from public.task_instances t where id=$1',[task]),before);
    assert.deepEqual(await scalar('select to_jsonb(w) from public.wallets w where child_id=$1',[child]),wallet);
    await client.query('reset role');
    const audit=await scalar("select jsonb_agg(details) from public.audit_logs where action='task.note_saved' and target_id=$1",[task]);
    assert.equal(audit.length,2); assert.equal(JSON.stringify(audit).includes('讨论'),false); await auth();
  });
  await check('note inspection is read-only and cancellation prevents delayed submit without reverting accepted content',async()=>{
    const id=randomUUID();
    assert.equal((await run('迟到的保存',id,'inspect')).status,'unknown');
    assert.equal((await run('迟到的保存',id,'cancel')).status,'abandoned');
    assert.equal((await run('迟到的保存',id)).status,'abandoned');
    assert.equal((await run('读到第三章，想讨论主人公的选择',original,'cancel')).status,'applied');
    assert.equal((await read()).version,2);
    await denied(sql,[task,original,'修改原请求','submit']);
    await denied(sql,[task,randomUUID(),'🪐'.repeat(501),'submit']);
    assert.equal((await run('🪐'.repeat(500))).current.body.length,1000);
    assert.equal((await run('')).current.body,'');
  });
  await check('task note table, receipts and RPCs reject foreign, anonymous and removed members',async()=>{
    await denied('select * from public.task_note_receipts');
    await denied('update public.task_notes set body=$1 where task_id=$2',['bypass',task]);
    await login(stranger,'notes-stranger'); await denied('select public.task_note($1)',[task]);
    await denied(sql,[task,randomUUID(),'foreign','submit']);
    assert.equal(await scalar('select count(*) from public.task_notes'),'0');
    await client.query('reset role'); await client.query('set role anon'); await denied('select public.task_note($1)',[task]);
    await client.query('reset role'); await client.query('delete from public.family_members where family_id=$1 and user_id=$2',[family,member]);
    await login(member,'note-member'); await denied('select public.task_note($1)',[task]);
    await denied(sql,[task,randomUUID(),'removed','submit']); await auth();
  });
  await check('two real sessions racing note submit and cancel converge without repeating the write',async()=>{
    const a=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});
    const b=new pg.Client({host:'127.0.0.1',port:54339,user:'postgres',database:'postgres'});
    try {
      for(const peer of [a,b]) {
        await peer.connect();
        await peer.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:owner,role:'authenticated',session_id:'task-notes'})]);
        await peer.query('set role authenticated');
      }
      const id=randomUUID(), before=(await read()).version;
      const results=await Promise.all([a.query(sql,[task,id,'竞争保存','submit']),b.query(sql,[task,id,'竞争保存','cancel'])]);
      const left=Object.values(results[0].rows[0])[0], right=Object.values(results[1].rows[0])[0];
      assert.equal(left.status,right.status); assert.equal(left.applied_version,right.applied_version);
      assert.equal((await read()).version,before+(left.status==='applied'?1:0));
      assert.equal((await run('竞争保存',id)).status,left.status);
    } finally { await a.end(); await b.end(); }
  });
  await check('task note export includes current shared text, excludes private receipts, and task deletion cascades',async()=>{
    await run('EXPORT NOTE');
    await client.query('reset role');
    const sections=await scalar('select public.child_export_source($1)',[child]);
    assert.equal(sections.length,40);
    assert.equal(sections.find(s=>s.name==='task_notes').rows[0].body,'EXPORT NOTE');
    assert.ok(sections.every(s=>s.name!=='task_note_receipts'));
    await client.query('delete from public.task_instances where id=$1',[task]);
    assert.equal(await scalar('select count(*) from public.task_notes where task_id=$1',[task]),'0');
    assert.equal(await scalar('select count(*) from public.task_note_receipts where task_id=$1',[task]),'0');
    await auth(); await denied('select public.task_note($1)',[task]);
  });
}
