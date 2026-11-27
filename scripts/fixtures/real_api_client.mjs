import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

export function realApiClient({url, anon, mailboxKey}) {
  const origin = new URL(url);
  assert.ok(origin.protocol === 'http:' && origin.hostname === '127.0.0.1');
  async function api(path, token = anon, {method = 'GET', body, type = 'application/json'} = {}) {
    const response = await fetch(`${url}${path}`, {method, headers: {apikey: anon,
      Authorization: `Bearer ${token}`, 'Content-Type': type},
    body: body === undefined ? undefined : Buffer.isBuffer(body) ? body : JSON.stringify(body),
    signal: AbortSignal.timeout(15000)});
    const text = await response.text();
    let data; try { data = JSON.parse(text); } catch { data = text; }
    return {status: response.status, data};
  }
  async function rpc(name, token, params = {}) {
    const result = await api(`/rest/v1/rpc/${name}`, token, {method: 'POST', body: params});
    assert.ok([200, 204].includes(result.status), `RPC ${name} failed (${result.status}): ${JSON.stringify(result.data)}`);
    return result.status === 204 ? null : result.data;
  }
  async function account() {
    const email = `integration-${randomUUID()}@example.test`;
    assert.equal((await api('/auth/v1/otp', anon, {method: 'POST', body: {email, create_user: true}})).status, 200);
    const mail = await fetch(`${url}/__test/mail?email=${encodeURIComponent(email)}`, {headers: {'x-test-mailbox-key': mailboxKey}});
    assert.equal(mail.status, 200);
    const response = await api('/auth/v1/verify', anon, {method: 'POST', body: {email, token: (await mail.json()).code, type: 'email'}});
    assert.equal(response.status, 200);
    return {token: response.data.access_token, id: response.data.user.id, email, session: response.data};
  }
  async function family(user) {
    const id = await rpc('onboard_family_profile', user.token, {family_name: '本机试卷家庭', family_timezone: 'Asia/Shanghai',
      child_nickname: '小星', child_grade: 2, preferences: {textbook_labels: {}, avatar_key: 'star'}});
    const children = await api(`/rest/v1/children?select=id&family_id=eq.${id}`, user.token);
    assert.equal(children.status, 200); assert.equal(children.data.length, 1);
    await rpc('set_parent_pin', user.token, {target_family_id: id, new_pin: '2468'});
    assert.equal((await rpc('verify_parent_pin', user.token, {target_family_id: id, candidate_pin: '2468'}))[0].verified, true);
    return {id, child: children.data[0].id};
  }
  return {api, rpc, account, family};
}
