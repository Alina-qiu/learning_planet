import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { PDFDocument } from 'pdf-lib';
import { renderWorksheet, validateWorksheetConfig, printablePinyin } from '../supabase/functions/_shared/worksheet_pdf.mjs';
import { snapshot } from './fixtures/worksheet_snapshot.mjs';

const font = await readFile('supabase/functions/worksheet-render/fonts/NotoSansSC-Regular.ttf');
assert.equal(printablePinyin('yin2hang2'),'yín háng');
assert.equal(printablePinyin('nv3 liu2 shui3 lü4 ye4'),'nǚ liú shuǐ lǜ yè');
assert.equal(createHash('sha256').update(font).digest('hex'), 'b6a3861ad594afe88f30c0eff922728198d51ac59323c922a29afc4322a7bead');
const first = await renderWorksheet(snapshot, font), second = await renderWorksheet(snapshot, font);
assert.deepEqual(first.bytes, second.bytes, 'identical immutable snapshot must produce identical bytes');
assert.equal(first.pages, 2);
assert.equal((await PDFDocument.load(first.bytes)).getPageCount(), 2);
assert.ok(first.trace.some(row => row.text.includes('lǜ yè')));
assert.ok(first.trace.some(row => row.text.includes('yín háng')));
for (const row of first.trace) {
  assert.ok(row.x >= first.size.margin);
  assert.ok(row.x + row.text_width <= first.size.width - first.size.margin + 0.01);
  assert.ok(row.baseline >= first.size.margin);
  assert.ok(row.baseline + row.size <= first.size.height - first.size.margin);
}
const questionsOnly = await renderWorksheet({ ...snapshot, config: { ...snapshot.config, include_answers: false, include_explanations: false } }, font);
assert.ok(!questionsOnly.trace.some(row => row.section === 'answers'));
assert.ok(!questionsOnly.trace.some(row => row.text.startsWith('答案：') || row.text.startsWith('解析：')));
const onlyExplanation = await renderWorksheet({ ...snapshot, config: { include_questions: false, include_answers: false, include_explanations: true } }, font);
assert.ok(!onlyExplanation.trace.some(row => row.text.startsWith('答案：')));
assert.ok(onlyExplanation.trace.some(row => row.text.startsWith('解析：')));
const landscape = await renderWorksheet({ ...snapshot, config: { orientation: 'landscape', pinyin_mode: 'pinyin_to_word' } }, font);
assert.ok(landscape.size.width > landscape.size.height);
assert.ok(landscape.trace.some(row => row.text.includes('看拼音写词语：yín háng')));
assert.ok(!landscape.trace.some(row => row.text.includes('语境：我去银行存钱')));
const mixed = await renderWorksheet({...snapshot,config:{pinyin_mode:'mixed'}},font);
assert.ok(mixed.trace.some(row => row.text.includes('给词语写拼音：')));
assert.ok(mixed.trace.some(row => row.text.includes('看拼音写词语：')));
// Deliberately exceed one page of writing space; short blocks now stay together.
const long = await renderWorksheet({ ...snapshot, config: { title: '长题与作答区分页验证', blank_lines: 12, repeats: 3 }, items: [
  { ...snapshot.items[0], prompt: '这是较长题目，阅读题干并按顺序完成回答。'.repeat(145) }, ...snapshot.items,
] }, font);
assert.ok(long.pages >= 4, `long fixture must exercise at least four pages, got ${long.pages}`);
assert.ok(long.trace.filter(row => row.text.includes('这是较长题目')).length > 10);
assert.ok(long.trace.some(row => row.text.includes('题作答区（续）')));
for (const invalid of [{ margin_mm: 11 }, { repeats: 0 }, { include_questions: false, include_answers: false, include_explanations: false }]) {
  assert.throws(() => validateWorksheetConfig(invalid), /INVALID_WORKSHEET_CONFIG/);
}
await assert.rejects(renderWorksheet({ ...snapshot, items: [{ ...snapshot.items[0], prompt: '不支持的表情😀' }] }, font), /UNSUPPORTED_FONT_GLYPH/);
await mkdir('tmp/pdfs', { recursive: true });
await writeFile('tmp/pdfs/worksheet-mixed.pdf', first.bytes);
await writeFile('tmp/pdfs/worksheet-questions.pdf', questionsOnly.bytes);
await writeFile('tmp/pdfs/worksheet-landscape.pdf', landscape.bytes);
await writeFile('tmp/pdfs/worksheet-long.pdf', long.bytes);
console.log(`PDF checks passed: deterministic ${first.bytes.length} bytes, mixed ${first.pages} pages, long ${long.pages} pages, A4 margins and switches. QA samples in tmp/pdfs.`);
