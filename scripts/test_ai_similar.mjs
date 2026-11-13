import assert from 'node:assert/strict';
import { openAiSimilar, normalizeSimilar, validateSimilarInput } from '../supabase/functions/_shared/ai_similar.mjs';
const input={kind:'similar',source_question_id:'12345678-1234-1234-1234-123456789012',source_version:2,text:'8+7=?',subject:'math',knowledge_point:'加法',difficulty:'easy'};
const value={prompt:'计算：9+6=?',answers:['15'],explanation:'9加1得到10，再加5得到15。',knowledge_point:'加法',difficulty:'easy',confidence:.85,safety_flags:[]};
let sent;
const fetcher=async(url,options)=>{assert.equal(url,'https://api.openai.com/v1/responses');sent=JSON.parse(options.body);
  return Response.json({status:'completed',output:[{type:'message',content:[{type:'output_text',text:JSON.stringify(value)}]}]});};
const result=await openAiSimilar('mock',fetcher)({model:'test-model',grade:2,input});
assert.deepEqual(JSON.parse(sent.input),{grade:2,subject:input.subject,text:input.text,knowledge_point:input.knowledge_point,difficulty:input.difficulty});
assert.equal(JSON.stringify(sent).includes(input.source_question_id),false);assert.equal(sent.store,false);assert.equal(sent.text.format.strict,true);
assert.equal(result.prompt_version,'similar-question-v1');assert.equal(result.structured_output.subject,'math');
assert.equal(result.structured_output.answer_check,undefined,'only the database may claim arithmetic verification');
assert.equal(validateSimilarInput(input),true);
for(const bad of [{...input,source_version:-1},{...input,source_question_id:'secret'},{...input,nickname:'private'},{...input,difficulty:'expert'},{...input,text:''}]) assert.equal(validateSimilarInput(bad),false);
for(const bad of [{...value,answers:[]},{...value,prompt:input.text},{...value,confidence:NaN},{...value,answer_check:{status:'passed'}},{...value,safety_flags:['made-up']}]) assert.throws(()=>normalizeSimilar(bad,'model',input,'raw'));
for(const flag of ['self_harm','violence','bullying','personal_data','not_a_question','refused']) {
  const blocked=normalizeSimilar({...value,safety_flags:[flag]},'model',input,'private text');
  assert.deepEqual(blocked.structured_output,{});assert.equal(blocked.raw_output,'');assert.equal(blocked.confidence,0);
}
const refusal=await openAiSimilar('mock',async()=>Response.json({status:'completed',output:[{type:'message',content:[{type:'refusal'}]}]}))({model:'model',grade:2,input});
assert.deepEqual(refusal.safety_flags,['refused']);
await assert.rejects(openAiSimilar('mock',async()=>Response.json({status:'incomplete',output:[]}))({model:'model',grade:2,input}));
console.log('Similar-question adapter checks passed: minimal inputs, strict output, identical-question rejection, safety/refusal redaction, and server-only answer verification.');
