import {boundedText} from './ai_analysis.mjs';

export const weeklyPromptVersion='weekly-report-v1';
export const evidenceIds=['tasks','daily','activities','reviews','due_now','coins'];
const safetyFlags=['self_harm','violence','bullying','personal_data','refused'];
const exact=(v,keys)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).sort().join(',')===[...keys].sort().join(',');
const count=n=>Number.isSafeInteger(n)&&n>=0&&n<1e15;
const date=s=>typeof s==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(s)&&Number.isFinite(Date.parse(s))&&new Date(`${s}T00:00:00Z`).toISOString().slice(0,10)===s;
export function validateWeeklyInput(input){
  try{
    if(!exact(input,['kind','end_date','snapshot'])||input.kind!=='weekly_report')return false;
    const s=input.snapshot;
    if(!exact(s,['schema_version','start_date','end_date','as_of_date','tasks','reviews','due_now','coins','activity_count','days'])||s.schema_version!=='weekly-facts-v1'
      ||![s.start_date,s.end_date,s.as_of_date].every(date)||input.end_date!==s.end_date||s.end_date<'2000-01-01'||s.as_of_date<s.end_date
      ||Date.parse(s.end_date)-Date.parse(s.start_date)!==6*86400000)return false;
    if(!exact(s.tasks,['expected','completed','effective_seconds'])||!exact(s.reviews,['answered','correct'])||!exact(s.coins,['income','spent','adjustment_out'])
      ||![...Object.values(s.tasks),...Object.values(s.reviews),...Object.values(s.coins),s.due_now,s.activity_count].every(count)
      ||s.tasks.completed>s.tasks.expected||s.reviews.correct>s.reviews.answered||!Array.isArray(s.days)||s.days.length!==7)return false;
    if(!s.days.every((d,i)=>exact(d,['day','expected','completed','effective_seconds'])
      &&d.day===new Date(Date.parse(s.start_date)+i*86400000).toISOString().slice(0,10)
      &&[d.expected,d.completed,d.effective_seconds].every(count)&&d.completed<=d.expected))return false;
    return ['expected','completed','effective_seconds'].every(k=>s.days.reduce((sum,d)=>sum+d[k],0)===s.tasks[k]);
  }catch{return false;}
}

const statementSchema={type:'object',additionalProperties:false,required:['text','evidence_ids'],properties:{
  text:{type:'string',maxLength:500},evidence_ids:{type:'array',minItems:1,maxItems:3,items:{type:'string',enum:evidenceIds}},
}};
export const weeklySchema={type:'object',additionalProperties:false,required:['summaries','recommendation','confidence','safety_flags'],properties:{
  summaries:{type:'array',minItems:1,maxItems:3,items:statementSchema},recommendation:statementSchema,
  confidence:{type:'number',minimum:0,maximum:1},safety_flags:{type:'array',maxItems:5,items:{type:'string',enum:safetyFlags}},
}};
function validStatement(s){
  return exact(s,['text','evidence_ids'])&&typeof s.text==='string'&&s.text.trim().length>0&&s.text.length<=500
    &&!/(懒惰|退步|笨蛋|差劲|没用|低能|智商|https?:\/\/|www\.|@)/i.test(s.text)
    &&Array.isArray(s.evidence_ids)&&s.evidence_ids.length>=1&&s.evidence_ids.length<=3
    &&s.evidence_ids.every(id=>evidenceIds.includes(id))&&new Set(s.evidence_ids).size===s.evidence_ids.length;
}
export function normalizeWeekly(value,model,raw){
  if(!exact(value,weeklySchema.required)||typeof value.confidence!=='number'||!Number.isFinite(value.confidence)||value.confidence<0||value.confidence>1
    ||!Array.isArray(value.safety_flags)||value.safety_flags.length>5||value.safety_flags.some(v=>!safetyFlags.includes(v)))throw new Error('AI_REPORT_INVALID');
  const blocked=value.safety_flags.length>0;
  if(!blocked&&(!Array.isArray(value.summaries)||value.summaries.length<1||value.summaries.length>3||!value.summaries.every(validStatement)||!validStatement(value.recommendation)))throw new Error('AI_REPORT_INVALID');
  return {model_version:model,prompt_version:weeklyPromptVersion,confidence:blocked?0:value.confidence,raw_output:blocked?'':raw,
    structured_output:blocked?{}:{summaries:value.summaries,recommendation:value.recommendation},safety_flags:value.safety_flags};
}
export function openAiWeeklyReport(apiKey,fetcher=fetch){
  return async({model,input})=>{
    if(!validateWeeklyInput(input))throw new Error('AI_REPORT_INPUT_INVALID');
    const response=await fetcher('https://api.openai.com/v1/responses',{
      method:'POST',signal:AbortSignal.timeout(20000),headers:{Authorization:`Bearer ${apiKey}`,'Content-Type':'application/json'},
      body:JSON.stringify({model,store:false,max_output_tokens:2500,
        instructions:'你为家长解读一份7天学习统计，只使用给定数字，以中文返回1至3条事实摘要和恰好一条可执行、温和、短小的行动建议。每条必须引用1至3个真实evidence_ids。来源tasks是按到期日分组的已生成任务，已批准请假排除；completed是这些任务目前已完成数量，effective_seconds是这些任务已保存计时之和，不表示在该周实际花费的全部时间。daily是同口径七天分布；activities是该日期范围实际完成的任务数，可能与tasks.completed不同。reviews是该周实际判定作答次数和正确次数；due_now是as_of_date当天的到期未掌握题数，并非历史周末状态。coins是该周实际金币收入、兑换消费和人工调减，冻结与退款不算产消。没有前一周数据，不推断环比、能力、掌握程度、原因或人格；样本为零时明确数据不足，不把0/0写成0%或100%。不得编造数值，结论引用必须与对应来源相符。建议不创建任务、不改奖励或掌握状态。避免懒惰、退步等判断性词语，不做诊断，不提供链接或联系方式。遇到安全问题设置对应safety_flags；输出严格符合JSON Schema。',
        input:JSON.stringify(input.snapshot),text:{format:{type:'json_schema',name:'weekly_report',strict:true,schema:weeklySchema}},
      }),
    });
    if(!response.ok){await response.body?.cancel();throw new Error('AI_PROVIDER_FAILED');}
    const body=JSON.parse(await boundedText(response.body,64000));
    if(body.status!=='completed'||!Array.isArray(body.output))throw new Error('AI_OUTPUT_INCOMPLETE');
    const contents=body.output.filter(v=>v.type==='message').flatMap(v=>v.content??[]);
    if(contents.some(v=>v.type==='refusal'))return normalizeWeekly({summaries:[],recommendation:{},confidence:0,safety_flags:['refused']},model,'');
    const texts=contents.filter(v=>v.type==='output_text');
    if(texts.length!==1||typeof texts[0].text!=='string'||texts[0].text.length>9000)throw new Error('AI_REPORT_INVALID');
    return normalizeWeekly(JSON.parse(texts[0].text),model,texts[0].text);
  };
}
