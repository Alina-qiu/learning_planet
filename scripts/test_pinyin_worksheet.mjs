import assert from 'node:assert/strict';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {renderWorksheet} from '../supabase/functions/_shared/worksheet_pdf.mjs';

// Confirmed import values; the same shape is checked against real SQL snapshots.
const words=[['银行','yín háng','我去银行存钱。'],['妈妈','mā ma','妈妈回家了。'],['不是','bú shì','这不是书。'],['一天','yì tiān','一天过去了。'],['绿叶','lǜ yè','树上长出绿叶。']];
const font=await readFile('supabase/functions/worksheet-render/fonts/NotoSansSC-Regular.ttf');
await mkdir('tmp/pdfs/pinyin-import',{recursive:true});
for(const mode of ['word_to_pinyin','pinyin_to_word','mixed']){
  const snapshot={id:'pinyin-import-'+mode,created_at:'2026-11-04T08:00:00Z',config:{
    title:'生词练习：轻声、变调与多音字',pinyin_mode:mode,grid:mode==='word_to_pinyin'?'four_lines':mode==='pinyin_to_word'?'tianzige':'both',
    repeats:2,include_answers:true,include_explanations:false,
  },items:words.map(([prompt,reading,context],index)=>({question_id:'word-'+index,review_kind:'pinyin',prompt,accepted_answers:[reading],pronunciation_context:context}))};
  const result=await renderWorksheet(snapshot,font);
  assert.deepEqual((await renderWorksheet(snapshot,font)).bytes,result.bytes);
  const prompts=result.trace.filter(row=>row.section==='questions').map(row=>row.text).join('\n');
  assert.ok(!prompts.includes('（续）'),'short word and both writing repetitions must stay on one page');
  assert.equal(prompts.includes('给词语写拼音：'),mode!=='pinyin_to_word');
  assert.equal(prompts.includes('看拼音写词语：'),mode!=='word_to_pinyin');
  if(mode==='pinyin_to_word') for(const [word,reading] of words){assert.ok(!prompts.includes(word));assert.ok(prompts.includes(reading));}
  for(const row of result.trace){
    assert.ok(row.x>=result.size.margin);
    assert.ok(row.x+row.text_width<=result.size.width-result.size.margin+.01);
    assert.ok(row.baseline>=result.size.margin);
  }
  await writeFile(`tmp/pdfs/pinyin-import/${mode}.pdf`,result.bytes);
  console.log(`PASS ${mode}: ${result.pages} pages, deterministic bytes, no word-answer leakage in reverse mode`);
}
