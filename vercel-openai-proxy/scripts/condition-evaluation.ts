import { ConditionPlan,Synthesis,validateConditionPlan,initialConditionState,nextConditionRequest } from '../api/_lib/condition-workflow';

export type EvaluationCase={name:string;entries:ConditionPlan['contextEntries'];preserved?:Synthesis;together:number[][];
  apart:number[][];unassigned:number[];forbidden:string[];required:Record<string,string[]>;primary:number|null};
export function evaluationPlan(fixture:EvaluationCase,contracts:Pick<ConditionPlan,'mapping'|'verification'>):ConditionPlan {
  const batches:ConditionPlan['batches']=[];
  const preserved=fixture.preserved??{groups:[],unassigned:[]};
  const retained=new Set([...preserved.groups.flatMap(g=>g.entryIDs),...preserved.unassigned]);
  for(const entry of fixture.entries.filter(e=>!retained.has(e.id))) {
    let batch=batches[batches.length-1];
    if(!batch || batch.length>=30 || Buffer.byteLength(JSON.stringify([...batch,entry]))>24000) batches.push(batch=[]);
    batch.push(entry);
  }
  const plan=validateConditionPlan({version:1,workload_type:'development',preserved,contextEntries:fixture.entries.filter(e=>retained.has(e.id)),batches,...contracts});
  // Exercise the actual production request builder as part of offline validation.
  if(plan.batches.length && !nextConditionRequest(plan,initialConditionState(plan))) throw new Error('missing_mapping_request');
  return plan;
}
export function assessConditionCase(fixture:EvaluationCase,result:Synthesis):string[] {
  const errors:string[]=[], ids=fixture.entries.map(e=>e.id);
  const assigned=[...result.groups.flatMap(g=>g.entryIDs),...result.unassigned];
  if(assigned.length!==ids.length || new Set(assigned).size!==ids.length || assigned.some(id=>!ids.includes(id))) errors.push('invalid_coverage');
  const groupFor=(index:number)=>result.groups.findIndex(g=>g.entryIDs.includes(ids[index]));
  for(const indexes of fixture.together) if(indexes.some(i=>groupFor(i)<0)||new Set(indexes.map(groupFor)).size!==1) errors.push('required_link_missing');
  for(const [a,b] of fixture.apart) if(groupFor(a)>=0 && groupFor(a)===groupFor(b)) errors.push('unsupported_link');
  for(const i of fixture.unassigned) if(!result.unassigned.includes(ids[i])) errors.push('unsupported_assignment');
  for(const term of fixture.forbidden) if(result.groups.some(g=>g.name.toLowerCase().includes(term.toLowerCase()))) errors.push('invented_heading');
  for(const [index,terms] of Object.entries(fixture.required)) {
    const group=result.groups[groupFor(Number(index))];
    if(!group || terms.some(term=>!group.name.toLowerCase().includes(term.toLowerCase()))) errors.push('required_name_missing');
  }
  if(fixture.primary!==null) {
    const primary=result.groups.filter(g=>g.isPrimary);
    if(primary.length!==1 || !primary[0].entryIDs.includes(ids[fixture.primary])) errors.push('priority_lost');
  }
  if(fixture.name.includes('eye') && result.groups.some(g=>g.bodySystem!=='eye')) errors.push('wrong_body_system');
  return [...new Set(errors)];
}
