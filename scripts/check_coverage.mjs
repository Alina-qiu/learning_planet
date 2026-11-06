import {readFile,readdir,stat,mkdir,writeFile} from 'node:fs/promises';
import {realpathSync} from 'node:fs';
import {resolve,relative,sep} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';

export function parseLcov(text,root){
  const sourceRoot=resolve(root),canonicalRoot=realpathSync(sourceRoot);
  const files=new Map();let current=null;
  for(const raw of text.split(/\r?\n/)){
    if(raw.startsWith('SF:')){
      let source=raw.slice(3).trim();
      if(source.startsWith('file:'))source=fileURLToPath(source);
      const resolved=resolve(sourceRoot,source.replace(/\\/g,'/'));
      let canonical=resolved;
      try{canonical=realpathSync(resolved);}catch(error){if(!['ENOENT','ENOTDIR'].includes(error.code))throw error;}
      const name=relative(canonicalRoot,canonical).split(sep).join('/');
      current=name.startsWith('lib/')?name:null;
      if(current&&!files.has(current))files.set(current,new Map());
    }else if(raw.startsWith('DA:')&&current){
      const fields=raw.slice(3).split(','),line=Number(fields[0]),hits=Number(fields[1]);
      if(!Number.isSafeInteger(line)||line<1||!Number.isSafeInteger(hits)||hits<0)throw new Error(`Invalid LCOV line data for ${current}`);
      const lines=files.get(current);lines.set(line,Math.max(hits,lines.get(line)??0));
    }else if(raw==='end_of_record')current=null;
  }
  if(files.size===0)throw new Error('LCOV has no repository lib/ sources');
  return files;
}
export async function checkCoverage({root=process.cwd(),lcov='coverage/lcov.info',policyFile='scripts/coverage_policy.json'}={}){
  root=resolve(root);
  const policy=JSON.parse(await readFile(resolve(root,policyFile),'utf8'));
  if(!Number.isFinite(policy.minimumLinePercent)||policy.minimumLinePercent<0||policy.minimumLinePercent>100)throw new Error('Invalid coverage threshold');
  const includes=policy.include.map(pattern=>new RegExp(pattern)),excludes=policy.exclude.map(pattern=>new RegExp(pattern));
  const records=parseLcov(await readFile(resolve(root,lcov),'utf8'),root),sources=[];
  async function walk(folder){
    for(const item of await readdir(resolve(root,folder),{withFileTypes:true})){
      const name=`${folder}/${item.name}`;
      if(item.isDirectory())await walk(name);
      else if(item.isFile()&&includes.some(pattern=>pattern.test(name))&&!excludes.some(pattern=>pattern.test(name)))sources.push(name);
    }
  }
  await walk('lib');sources.sort();if(!sources.length)throw new Error('Coverage scope contains no Dart sources');
  const missing=[],stale=[],files=[];
  const coverageTime=(await stat(resolve(root,lcov))).mtimeMs;
  for(const name of sources){
    const source=await readFile(resolve(root,name),'utf8'),lineCount=source.split(/\r?\n/).length,record=records.get(name);
    if((await stat(resolve(root,name))).mtimeMs>coverageTime+1000)stale.push(name);
    if(!record||record.size===0){missing.push(name);continue;}
    for(const line of record.keys())if(line>lineCount)throw new Error(`LCOV source mismatch: ${name}:${line}`);
    const total=record.size,covered=[...record.values()].filter(hits=>hits>0).length;
    files.push({name,covered,total,percent:100*covered/total,uncovered:[...record].filter(([,hits])=>hits===0).map(([line])=>line).sort((a,b)=>a-b)});
  }
  const covered=files.reduce((sum,f)=>sum+f.covered,0),total=files.reduce((sum,f)=>sum+f.total,0),percent=total?100*covered/total:0;
  return {minimumLinePercent:policy.minimumLinePercent,sourceCount:sources.length,covered,total,percent,missing,stale,files,
    passed:total>0&&percent>=policy.minimumLinePercent&&stale.length===0&&(!policy.requireAllSourceRecords||missing.length===0)};
}

if(process.argv[1]&&import.meta.url===pathToFileURL(realpathSync(resolve(process.argv[1]))).href){
  try{
    const report=await checkCoverage();
    await mkdir('coverage',{recursive:true});await writeFile('coverage/core-summary.json',JSON.stringify(report,null,2)+'\n');
    console.log(`Core line coverage: ${report.covered}/${report.total} (${report.percent.toFixed(2)}%); required ${report.minimumLinePercent}%; ${report.sourceCount} source files.`);
    for(const name of report.missing)console.log(`MISSING ${name}`);
    for(const name of report.stale)console.log(`STALE ${name}`);
    for(const f of report.files.filter(f=>f.covered<f.total).sort((a,b)=>(b.total-b.covered)-(a.total-a.covered)).slice(0,12))console.log(`${f.name}: ${f.covered}/${f.total} (${f.percent.toFixed(1)}%), ${f.total-f.covered} lines not exercised`);
    console.log(report.passed?'Coverage gate passed.':'Coverage gate failed. See coverage/core-summary.json.');
    if(!report.passed)process.exitCode=1;
  }catch(error){console.error(error.message);process.exitCode=1;}
}
