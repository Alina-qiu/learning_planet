import assert from 'node:assert/strict';
import {validateWeeklyInput,normalizeWeekly,openAiWeeklyReport} from '../supabase/functions/_shared/ai_weekly_report.mjs';
import {weeklyInput as input,weeklyValue as value} from './fixtures/weekly_report.mjs';
assert.equal(validateWeeklyInput(input),true);
for(const changed of [{...input,child_id:'private'}, {...input,snapshot:{...input.snapshot,title:'private'}},
  {...input,snapshot:{...input.snapshot,tasks:{...input.snapshot.tasks,completed:3}}},
  {...input,snapshot:{...input.snapshot,days:input.snapshot.days.slice(1)}},
  {...input,end_date:'2026-02-30'}, {...input,snapshot:{...input.snapshot,due_now:-1}}])assert.equal(validateWeeklyInput(changed),false);
let sent,calls=0;
const provider=async(url,options)=>{calls++;assert.equal(url,'https://api.openai.com/v1/responses');sent=JSON.parse(options.body);
  return Response.json({status:'completed',output:[{type:'message',content:[{type:'output_text',text:JSON.stringify(value)}]}]});};
const result=await openAiWeeklyReport('mock',provider)({model:'test-model',grade:3,input});
assert.deepEqual(JSON.parse(sent.input),input.snapshot);assert.equal(sent.store,false);assert.equal(sent.max_output_tokens,2500);
assert.equal(sent.text.format.strict,true);assert.equal(sent.tools,undefined);assert.equal(JSON.parse(sent.input).grade,undefined);
assert.equal(result.prompt_version,'weekly-report-v1');assert.deepEqual(result.structured_output.summaries,value.summaries);
for(const statement of [{text:'编造来源',evidence_ids:['task-id']},{text:'退步了',evidence_ids:['tasks']},
  {text:'链接 https://example.test',evidence_ids:['tasks']},{text:'x',evidence_ids:[]},{text:'x',evidence_ids:['tasks','tasks']}]){
  assert.throws(()=>normalizeWeekly({...value,recommendation:statement},'test-model','raw'),/AI_REPORT_INVALID/);
}
assert.throws(()=>normalizeWeekly({...value,confidence:NaN},'test-model','raw'));
assert.throws(()=>normalizeWeekly({...value,summaries:[]},'test-model','raw'));
const blocked=normalizeWeekly({...value,safety_flags:['personal_data']},'test-model','sensitive');
assert.deepEqual(blocked.structured_output,{});assert.equal(blocked.raw_output,'');assert.equal(blocked.confidence,0);
const refused=await openAiWeeklyReport('mock',async()=>Response.json({status:'completed',output:[{type:'message',content:[{type:'refusal',refusal:'no'}]}]}))({model:'test-model',input});
assert.deepEqual(refused.safety_flags,['refused']);
await assert.rejects(openAiWeeklyReport('mock',provider)({model:'test-model',input:{...input,nickname:'private'}}));assert.equal(calls,1);
console.log('Weekly report adapter passed: aggregate-only input, strict evidence references, nonjudgmental output, refusal suppression and bounded provider response. All provider HTTP mocked.');
