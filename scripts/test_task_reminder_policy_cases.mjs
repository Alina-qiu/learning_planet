import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

export async function taskReminderPolicyCases({client,scalar,login,denied,check}) {
  const owner=randomUUID();
  await client.query('reset role');
  await client.query('insert into auth.users values($1,$2)',[owner,'reminder-policy@example.test']);
  const auth=()=>login(owner,'reminder-policy');
  await auth();
  await client.query("select public.onboard_family('Reminder policy','America/New_York','Test',1::smallint)");
  const family=await scalar('select id from public.families where owner_user_id=$1',[owner]);
  const child=await scalar('select id from public.children where family_id=$1',[family]);
  await client.query("select public.set_parent_pin($1,'2468')",[family]);
  await client.query("select public.verify_parent_pin($1,'2468')",[family]);
  const today=await scalar('select public.family_today($1)',[child]);
  const until=await scalar('select ($1::date+3)::text',[today]);
  await client.query('select public.save_task_schedule($1,$2)',[child,{title:'Synthetic reminder',recurrence:'daily',starts_on:today,ends_on:until,start_time:'16:00',due_time:'20:00',coins:5,xp:5,minimum_seconds:0}]);
  const rows=async()=>(await client.query('select * from public.load_task_reminders($1)',[child])).rows;
  await check('task reminders include the authoritative default family quiet policy without client guesses',async()=>{
    const result=await rows();assert.ok(result.length>0);
    for(const row of result) assert.deepEqual(row.delivery_policy,{version:'task-reminder-v1',timezone:'America/New_York',quiet_start:'21:00:00',quiet_end:'07:00:00'});
    assert.ok(result.every(row=>Array.isArray(row.tasks)&&row.tasks.length>0));
  });
  await check('task policy changes and disabled reminders retain filtering and access control',async()=>{
    await client.query("insert into public.reminder_settings(child_id,enabled,quiet_start,quiet_end) values($1,true,'16:00','17:00') on conflict(child_id) do update set quiet_start='16:00',quiet_end='17:00'",[child]);
    const result=await rows();assert.ok(result.length>0);
    assert.ok(result.every(row=>row.delivery_policy.quiet_start==='16:00:00' && row.delivery_policy.quiet_end==='17:00:00'));
    assert.ok(result.every(row=>!row.remind_local.includes('16:00')));
    await client.query('update public.reminder_settings set enabled=false where child_id=$1',[child]);
    assert.equal((await rows()).length,0);
    await login();await denied('select * from public.load_task_reminders($1)',[child]);
    await client.query('reset role');await client.query('set role anon');
    await denied('select * from public.load_task_reminders($1)',[child]);
  });
  await login();
}
