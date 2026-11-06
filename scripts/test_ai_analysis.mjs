import assert from 'node:assert/strict';
import { openAiAnalyzer, executeAnalysis, normalizeAnalysis, validateInput, boundedText } from '../supabase/functions/_shared/ai_analysis.mjs';
const input={text:'8 + 7 = ?',subject:'math'};
const value={knowledge_points:['进位加法'],difficulty:'easy',error_reasons:['calculation'],confidence:.7,safety_flags:[]};
const claim={request_id:'request',token:'token',model:'test-model',grade:2};
let sent, calls=0;
const fetcher=async(url,options)=>{
  calls++; sent=JSON.parse(options.body);
  assert.equal(url,'https://api.openai.com/v1/responses');
  assert.equal(options.headers.Authorization,'Bearer fake-key');
  return Response.json({status:'completed',output:[{type:'message',content:[{type:'output_text',text:JSON.stringify(value)}]}]});
};
const result=await openAiAnalyzer('fake-key',fetcher)({...claim,input:{...input,nickname:'DO NOT SEND',child_id:'private'}});
assert.deepEqual(JSON.parse(sent.input),{grade:2,...input}); assert.equal(JSON.stringify(sent).includes('DO NOT SEND'),false);
assert.equal(sent.store,false); assert.equal(sent.max_output_tokens,1500); assert.equal(sent.text.format.strict,true);
assert.equal(sent.tools,undefined); assert.equal(result.model_version,'test-model'); assert.equal(result.prompt_version,'question-structure-v1');
assert.equal(result.raw_output,JSON.stringify(value)); assert.equal(result.confidence,.7);
for(const bad of [{...value,coins:10},{...value,confidence:2},{...value,confidence:NaN},
  {...value,difficulty:'expert'},{...value,knowledge_points:['x'.repeat(61)]}, {...value,error_reasons:['lazy']},
  {...value,safety_flags:['unsafe-unknown']}]) assert.throws(()=>normalizeAnalysis(bad,'test-model','raw'));
for(const flag of ['self_harm','violence','bullying','personal_data','not_a_question','refused']) {
  const safe=normalizeAnalysis({...value,safety_flags:[flag]},'test-model','PRIVATE RAW');
  assert.equal(safe.raw_output,''); assert.equal(safe.confidence,0); assert.deepEqual(safe.structured_output.knowledge_points,[]);
}
for(const body of [{status:'incomplete',output:[]},{status:'completed',output:[]},
  {status:'completed',output:[{type:'message',content:[{type:'output_text',text:'not json'}]}]}]) {
  await assert.rejects(openAiAnalyzer('fake',async()=>Response.json(body))({...claim,input}));
}
const refusal=await openAiAnalyzer('fake',async()=>Response.json({status:'completed',output:[{type:'message',content:[{type:'refusal',refusal:'PRIVATE'}]}]}))({...claim,input});
assert.deepEqual(refusal.safety_flags,['refused']); assert.equal(refusal.raw_output,'');
assert.equal(validateInput(input),true); assert.equal(validateInput({...input,child_id:'secret'}),false); assert.equal(validateInput({...input,text:''}),false);
await assert.rejects(boundedText(new Response('x'.repeat(128)).body,127));
let analyzed=0, completed;
await executeAnalysis(claim,input,{analyze:async()=>{analyzed++;throw new Error('unknown provider outcome');},finish:async(id,token,output)=>{completed={id,token,output};}});
assert.equal(analyzed,1); assert.deepEqual(completed,{id:'request',token:'token',output:null});
await assert.rejects(executeAnalysis(claim,input,{analyze:async()=>{analyzed++;return result;},finish:async()=>{throw new Error('finish lost');}}));
assert.equal(analyzed,2,'a lost finish acknowledgement must not call the provider twice');
assert.equal(calls,1);
console.log('AI adapter/worker checks passed: minimal input, strict contract, refusals, safety redaction, bounded payload, no automatic paid retries.');
