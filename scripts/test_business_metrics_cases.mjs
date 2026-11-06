import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

export async function businessMetricsCases({client,scalar,login,denied,check}) {
  const owner=randomUUID(),peer=randomUUID(),outsider=randomUUID();
  await client.query('reset role');
  for (const id of [owner,peer,outsider]) await client.query('insert into auth.users values($1,$2)',[id,`${id}@metrics.test`]);
  const family=await scalar("insert into public.families(name,timezone,owner_user_id) values('metrics','America/New_York',$1) returning id",[owner]);
  await client.query("insert into public.family_members values($1,$2,'admin'),($1,$3,'parent')",[family,owner,peer]);
  const child=await scalar("insert into public.children(family_id,nickname,grade) values($1,'PRIVATE CHILD',2) returning id",[family]);
  const sibling=await scalar("insert into public.children(family_id,nickname,grade) values($1,'PRIVATE SIBLING',2) returning id",[family]);
  await client.query('insert into public.wallets(child_id) values($1),($2)',[child,sibling]);
  const reward=await scalar("insert into public.rewards(family_id,title,cost) values($1,'PRIVATE REWARD',10) returning id",[family]);
  const report=(period='day',anchor='2026-03-08',id=child)=>scalar('select public.learning_report($1,$2,$3)',[id,period,anchor]);
  const metrics=async(...args)=>(await report(...args)).business_metrics;
  const auth=async(user=owner)=>{await login(user);await scalar("select public.verify_parent_pin($1,'1234')",[family]);};
  async function redeem(created,fulfilled,status='fulfilled',id=child) {
    return scalar(`insert into public.redemptions(child_id,reward_id,frozen_amount,status,created_at,fulfilled_at,expires_at)
      values($1,$2,10,$3,$4,$5,'2030-01-01') returning id`,[id,reward,status,created,fulfilled]);
  }
  await redeem('2026-03-07T05:00Z','2026-03-08T05:00Z'); // 24h at inclusive lower boundary
  await redeem('2026-03-08T05:00Z','2026-03-09T03:00Z'); // 22h, median = 23h
  await redeem('2026-03-08T05:00Z','2026-03-09T04:00Z'); // exclusive next local day
  await redeem('2026-03-08T13:00Z','2026-03-08T12:00Z'); // invalid historical duration
  await redeem('2026-03-08T05:00Z',null); // legacy missing fulfillment time
  await redeem('2026-03-08T06:00Z',null,'requested');
  await redeem('2026-03-08T07:00Z',null,'approved');
  await redeem('2026-03-08T08:00Z',null,'rejected');
  await redeem('2026-03-08T08:00Z',null,'cancelled');
  await redeem('2026-03-08T00:00Z','2026-03-08T16:00Z','fulfilled',sibling);
  // Both repeated 01:30 instants belong to the 25-hour fall-back day.
  await redeem('2026-11-01T04:30Z','2026-11-01T05:30Z');
  await redeem('2026-11-01T04:30Z','2026-11-01T06:30Z');
  await redeem('2026-11-01T04:30Z','2026-11-02T05:00Z');
  await redeem('2026-02-15T09:00Z','2026-02-15T10:00Z');
  await redeem('2026-02-15T08:00Z','2026-02-15T10:00Z');
  await redeem('2026-02-11T06:00Z','2026-02-15T10:00Z');
  async function ledger(amount,frozen,source,time='2026-03-08T10:00Z',id=child) {
    await client.query(`insert into public.ledger_entries(child_id,asset_type,amount,frozen_delta,source_type,idempotency_key,created_at)
      values($1,'coin',$2,$3,$4,$5,$6)`,[id,amount,frozen,source,randomUUID(),time]);
  }
  await ledger(100,0,'parent_adjustment');await ledger(-40,40,'redemption_freeze');
  await ledger(40,-40,'redemption_refund');await ledger(-20,20,'redemption_freeze');await ledger(0,-20,'redemption_spend');
  await ledger(-5,0,'parent_adjustment');await ledger(99,0,'parent_adjustment','2026-03-09T04:00Z');
  await ledger(900,0,'parent_adjustment','2026-03-08T10:00Z',sibling);

  // Seed known historical aggregates without pretending that old records can be
  // reconstructed from today's edited text. The trigger is tested via real RPCs below.
  async function historicalOcr(at,fields,corrected,id=child) {
    const question=await scalar("insert into public.wrong_questions(child_id,subject,final_text) values($1,'math','PRIVATE QUESTION') returning id",[id]);
    const draft=randomUUID();
    await client.query(`insert into public.question_ocr_drafts(id,child_id,owner_id,status,question_id,original_path,processed_path,raw_text)
      values($1,$2,$3,'saved',$4,$5,$6,'PRIVATE OCR')`,[draft,id,owner,question,`${family}/${draft}/original.jpg`,`${family}/${draft}/processed.jpg`]);
    if (at) {
      await client.query('alter table public.question_ocr_drafts disable trigger capture_ocr_confirmation_metrics');
      try { await client.query(`update public.question_ocr_drafts set metrics_confirmed_at=$2,metrics_ocr_fields=$3,metrics_corrected_fields=$4 where id=$1`,[draft,at,fields,corrected]); }
      finally { await client.query('alter table public.question_ocr_drafts enable trigger capture_ocr_confirmation_metrics'); }
    }
    return {draft,question};
  }
  const same=await historicalOcr('2026-03-08T05:00Z',1,0);
  const changed=await historicalOcr('2026-03-09T03:59:59Z',1,1);
  await historicalOcr('2026-03-08T11:00Z',0,0);
  await historicalOcr('2026-03-09T04:00Z',1,1);
  await historicalOcr(null,null,null);
  await historicalOcr('2026-03-08T11:00Z',1,1,sibling);
  await login(owner);await scalar("select public.set_parent_pin($1,'1234')",[family]);await auth();

  await check('business reports use fulfilled cohorts, median rather than average, and 23/25-hour family days',async()=>{
    const m=await metrics();
    assert.equal(m.version,'business-v1');
    assert.deepEqual(m.fulfillment,{samples:2,median_seconds:82800,open_requests:2});
    assert.deepEqual((await metrics('day','2026-11-01')).fulfillment,{samples:2,median_seconds:5400,open_requests:0});
    assert.equal((await metrics('day','2026-02-15')).fulfillment.median_seconds,7200);
    assert.equal((await report('month','2026-03-05')).end_date,'2026-03-31');
    assert.equal((await metrics('month','2026-03-05')).fulfillment.samples,3);
    assert.equal((await metrics('week','2026-03-08')).fulfillment.samples,2);
    assert.doesNotMatch(JSON.stringify(m),/PRIVATE|raw_text|question_id|reward_id/);
  });
  await check('coin production-to-consumption excludes freeze/refund and separately reports manual debits',async()=>{
    const r=await report();
    assert.deepEqual(r.coins,{income:100,spent:20,adjustment_out:5,xp:0});
    assert.equal(r.business_metrics.coin_income_to_spent,5);
    const empty=await metrics('day','2026-02-01');
    assert.equal(empty.coin_income_to_spent,null);
    assert.deepEqual(empty.fulfillment,{samples:0,median_seconds:null,open_requests:0});
    await client.query('reset role');await ledger(-10,10,'redemption_freeze','2026-02-02T11:00Z');await ledger(0,-10,'redemption_spend','2026-02-02T12:00Z');await auth();
    assert.equal((await metrics('day','2026-02-02')).coin_income_to_spent,0);
  });
  await check('OCR quality uses first confirmations, excludes manual/unknown fields, and returns no false zero',async()=>{
    assert.deepEqual((await metrics()).ocr,{ocr_fields:2,corrected_fields:1,correction_rate:0.5,manual_records:1,unmeasured_saved_records:1});
    assert.equal((await metrics('month','2026-03-08')).ocr.correction_rate,0.6667);
    assert.equal((await metrics('day','2026-02-01')).ocr.correction_rate,null);
    await client.query('reset role');
    await client.query("update public.wrong_questions set final_text='LATER EDIT' where id=$1",[same.question]);
    await client.query('update public.question_ocr_drafts set metrics_corrected_fields=1,metrics_confirmed_at=now() where id=$1',[same.draft]);
    await auth();assert.equal((await metrics()).ocr.correction_rate,0.5);
  });
  let rpcDraft,rpcQuestion;
  await check('real OCR confirm freezes one text field once, ignores outer whitespace, and never records manual answers as OCR',async()=>{
    async function confirm(raw,prompt,manual=false) {
      const id=randomUUID();const draft=await scalar('select public.begin_question_ocr($1,$2)',[child,id]);
      await client.query("insert into storage.objects(bucket_id,name) values('wrong-question-images',$1),('wrong-question-images',$2)",[draft.original_path,draft.processed_path]);
      if(manual) await scalar('select public.manual_question_ocr($1)',[id]);
      else await scalar('select public.record_question_ocr($1,$2)',[id,{text:raw}]);
      const config={kind:'question',subject:'math',prompt,answers:['SECRET ANSWER'],ocr_confirmed:true,ocr_draft_id:id};
      const question=await scalar('select public.save_review_question($1,$2)',[child,config]);
      const before=await scalar('select to_jsonb(d) from public.question_ocr_drafts d where id=$1',[id]);
      assert.equal(await scalar('select public.save_review_question($1,$2)',[child,config]),question);
      const after=await scalar('select to_jsonb(d) from public.question_ocr_drafts d where id=$1',[id]);
      assert.deepEqual(after,before);
      assert.ok(Math.abs(Date.parse(after.metrics_confirmed_at)-Date.now())<30000);
      return {id,question,row:after};
    }
    const unchanged=await confirm('  2+2  ','2+2');assert.equal(unchanged.row.metrics_ocr_fields,1);assert.equal(unchanged.row.metrics_corrected_fields,0);
    const corrected=await confirm('2+Z','2+2');assert.equal(corrected.row.metrics_corrected_fields,1);
    const manual=await confirm(null,'Manual prompt',true);assert.equal(manual.row.metrics_ocr_fields,0);assert.equal(manual.row.metrics_corrected_fields,0);
    rpcDraft=corrected.id;rpcQuestion=corrected.question;
    const current=await metrics('day',null);
    assert.equal(current.ocr.ocr_fields,2);assert.equal(current.ocr.corrected_fields,1);assert.equal(current.ocr.manual_records,1);
    assert.doesNotMatch(JSON.stringify(current),/SECRET ANSWER|2\+Z|Manual prompt/);
  });
  await check('metrics require current-session PIN and visible child, and internal/pre-migration reports are not callable',async()=>{
    await denied("select public.learning_report_before_business_metrics($1,'day',null)",[child]);
    await denied('select public.capture_ocr_confirmation_metrics()');
    await denied('update public.question_ocr_drafts set metrics_ocr_fields=1 where id=$1',[rpcDraft]);
    await login(owner,'metrics-no-pin');await assert.rejects(report());
    await login(outsider);await assert.rejects(report());
    await client.query('reset role');await client.query('set role anon');await assert.rejects(report());
    await auth(peer);assert.equal((await metrics()).fulfillment.samples,2);await auth();
    await assert.rejects(report('day',null,randomUUID()));
  });
  await check('OCR metadata follows child export and permanent cleanup, without changing rewards or business states',async()=>{
    const preview=await scalar('select public.preview_child_export($1)',[child]);
    const exported=await scalar("select public.prepare_child_export($1,$2,$3,'导出孩子数据')",[child,randomUUID(),preview.counts]);
    const section=await scalar("select public.read_child_export_page($1,'ocr_records',0)",[exported.id]);
    const row=section.rows.find(r=>r.id===rpcDraft);
    assert.equal(row.metrics_ocr_fields,1);assert.equal(row.metrics_corrected_fields,1);assert.ok(row.metrics_confirmed_at);
    assert.ok(exported.sections.find(s=>s.name==='ocr_records').columns.includes('metrics_confirmed_at'));
    const before=await scalar('select count(*) from public.ledger_entries where child_id=$1',[child]);
    await report();await report();assert.equal(await scalar('select count(*) from public.ledger_entries where child_id=$1',[child]),before);
    await scalar("select public.request_question_cleanup($1,'questions',$2,$3,'永久删除')",[child,[rpcQuestion],randomUUID()]);
    assert.equal((await metrics('day',null)).ocr.ocr_fields,1);
    await client.query('reset role');
    await client.query('delete from public.question_ocr_drafts where id=$1',[changed.draft]);
    await auth();assert.equal((await metrics()).ocr.corrected_fields,0);
    const deletion=await scalar('select public.preview_child_deletion($1)',[sibling]);
    await scalar("select public.request_child_deletion($1,$2,$3,'永久删除孩子')",[sibling,randomUUID(),deletion.counts]);
    await assert.rejects(report('day',null,sibling));
  });
  await login();
}
