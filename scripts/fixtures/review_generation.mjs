import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import pg from 'pg';

// These fixtures need an open family day regardless of the CI runner's clock.
export function daytimeReviewZone(scalar) {
  return scalar(`select name from pg_timezone_names where name like 'Etc/GMT%'
    and extract(hour from now() at time zone name)=12 order by name limit 1`);
}

// Observe an actual database wait between public RPCs before committing the
// question change. This also reproduces the old race in the upgrade suite.
export async function generateDuringReviewChange(client, child, change, whileBlocked) {
  const claims = (await client.query('select auth.jwt() as claims')).rows[0].claims;
  const peer = new pg.Client(client.connectionParameters);
  let transactionOpen = false, pending;
  try {
    await peer.connect();
    await peer.query("select set_config('request.jwt.claims',$1,false)", [
      JSON.stringify({...claims, session_id: randomUUID()}),
    ]);
    await peer.query('set role authenticated');
    await peer.query("set statement_timeout = '15s'");
    const pid = (await peer.query('select pg_backend_pid() as pid')).rows[0].pid;
    await client.query('begin');
    transactionOpen = true;
    await change();
    pending = peer.query('select public.generate_daily_wrong_review_task($1) as task', [child])
      .then(result => ({task: result.rows[0].task}), error => ({error}));
    const deadline = Date.now() + 8000;
    for (;;) {
      const {rows} = await client.query('select pg_backend_pid() = any(pg_blocking_pids($1)) as blocked', [pid]);
      if (rows[0].blocked) break;
      assert.ok(Date.now() < deadline, 'The generator did not wait for the question change');
      await delay(10);
    }
    if (whileBlocked) await whileBlocked();
    await client.query('commit');
    transactionOpen = false;
    const result = await pending;
    if (result.error) throw result.error;
    return result.task;
  } finally {
    if (transactionOpen) await client.query('rollback');
    if (pending) await pending;
    await peer.end();
  }
}
