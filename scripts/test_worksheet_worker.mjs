import assert from 'node:assert/strict';
import { executeWorksheet } from '../supabase/functions/_shared/worksheet_worker.mjs';
import { RENDERER_VERSION } from '../supabase/functions/_shared/worksheet_pdf.mjs';
const claim = { id: 'job', status: 'claimed', lease_token: 'token', pdf_path: '10000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000001/worksheet.pdf', snapshot: {} };
function fixture(options = {}) {
  const events = [];
  return { events, adapter: {
    progress: async (id, token, percentage) => { events.push(['progress', percentage]); if (options.failProgress === percentage) throw new Error('LEASE_INVALID'); },
    render: async () => { events.push(['render']); if (options.renderError) throw new Error(options.renderError); return { bytes: new Uint8Array(8), pages: 1, renderer_version: RENDERER_VERSION }; },
    hash: async () => 'abc',
    upload: async () => { events.push(['upload']); if (options.uploadError) throw new Error('PDF_UPLOAD_FAILED'); },
    finish: async (id, token, result) => { events.push(['finish', result]); if (options.finishError && !result.error_code) throw new Error('ACK_LOST'); },
    state: async () => { if (options.stateUnknown) throw new Error('NETWORK'); return options.state ?? { status: 'running' }; },
    remove: async path => { events.push(['remove', path]); },
  } };
}
{
  const f = fixture(); assert.equal(await executeWorksheet(claim, f.adapter), 'ready');
  assert.deepEqual(f.events.map(e => e[0]), ['progress', 'render', 'progress', 'upload', 'progress', 'finish']);
  assert.equal(f.events.at(-1)[1].sha256, 'abc');
}
{
  const f = fixture({ renderError: 'UNSUPPORTED_FONT_GLYPH' });
  assert.equal(await executeWorksheet(claim, f.adapter), 'failed');
  assert.ok(!f.events.some(e => e[0] === 'upload')); assert.equal(f.events.at(-1)[1].error_code, 'UNSUPPORTED_FONT_GLYPH');
}
{
  const f = fixture({ failProgress: 75 }); assert.equal(await executeWorksheet(claim, f.adapter), 'failed');
  assert.ok(!f.events.some(e => e[0] === 'upload'));
}
{
  const f = fixture({ uploadError: true }); assert.equal(await executeWorksheet(claim, f.adapter), 'failed');
  assert.equal(f.events.at(-1)[1].error_code, 'PDF_UPLOAD_FAILED');
}
{
  const f = fixture({ finishError: true, state: { status: 'ready', sha256: 'abc' } });
  assert.equal(await executeWorksheet(claim, f.adapter), 'ready'); assert.ok(!f.events.some(e => e[0] === 'remove'));
}
{
  const f = fixture({ finishError: true, stateUnknown: true });
  assert.equal(await executeWorksheet(claim, f.adapter), 'failed'); assert.ok(!f.events.some(e => e[0] === 'remove'));
}
{
  const f = fixture({ failProgress: 90, state: { status: 'deleting' } });
  assert.equal(await executeWorksheet(claim, f.adapter), 'failed'); assert.ok(f.events.some(e => e[0] === 'remove'));
}
{
  const f = fixture(); assert.equal(await executeWorksheet({ ...claim, status: 'ready' }, f.adapter), 'ready'); assert.equal(f.events.length, 0);
}
console.log('All 8 PDF worker checks passed. Adapter is injected; Edge deployment is not exercised.');
