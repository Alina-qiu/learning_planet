export const weeklyInput={kind:'weekly_report',end_date:'2026-03-08',snapshot:{
  schema_version:'weekly-facts-v1',start_date:'2026-03-02',end_date:'2026-03-08',as_of_date:'2026-11-04',
  tasks:{expected:2,completed:1,effective_seconds:720},reviews:{answered:2,correct:1},
  due_now:1,coins:{income:5,spent:0,adjustment_out:0},activity_count:2,
  days:Array.from({length:7},(_,i)=>({day:`2026-03-0${i+2}`,expected:i<2?1:0,completed:i===0?1:0,effective_seconds:i===0?600:i===1?120:0})),
}};
export const weeklyValue={summaries:[{text:'本周到期的2项任务中已完成1项。',evidence_ids:['tasks']}],
  recommendation:{text:'可以先和孩子一起安排一小段到期复习。',evidence_ids:['due_now','reviews']},confidence:.72,safety_flags:[]};
