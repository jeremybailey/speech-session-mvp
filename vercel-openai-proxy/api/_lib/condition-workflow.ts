import { Payload, WorkloadType, validatePayload } from './ledger';

// Deterministic coordinator only: no network calls, no inference, no inferred links.
export type Entry = { id: string; patientAssigned?: boolean; [key: string]: unknown };
export type Group = { name: string; bodySystem: string; isPrimary: boolean; reason: string;
  entryIDs: string[]; stableID?: string; entryReasons?: string[] };
export type Synthesis = { groups: Group[]; unassigned: string[] };
type Contract = { instructions: string; response_format: Record<string, unknown> };
export type ConditionPlan = { version: 1; workload_type?:WorkloadType; preserved: Synthesis; batches: Entry[][];
  contextEntries: Entry[]; mapping: Contract; verification: Contract };
export type ConditionState = { batch: number; phase: 'mapping'|'verification'|'completed';
  result: Synthesis; proposal?: Synthesis; verificationBatches?: Group[][]; verificationIndex: number };
const systems = new Set(['eye','neurological','musculoskeletal','cardiovascular','respiratory',
  'digestive','endocrine','reproductive','urinary','skin','immune','mental','ear','unknown']);
function requireValue(ok: unknown): asserts ok { if (!ok) throw new Error('invalid_condition_workflow'); }
const bytes = (value: unknown) => Buffer.byteLength(JSON.stringify(value));
// Mirrors ConditionSummaryProjection's narrow aliases, never clinical inference.
function normalized(name:string) {
  const aliases:Record<string,string>={migraines:'migraine',headaches:'headache',knapsack:'backpack'};
  return name.normalize('NFD').replace(/\p{M}/gu,'').toLowerCase().split(/[^\p{L}\p{N}]+/u)
    .filter(Boolean).map(word=>aliases[word]??word).join(' ');
}
function conditionKey(name:string) {
  let value=normalized(name);
  for(const [alias,canonical] of [['pins and needles','tingling'],['back ache','back pain'],['backache','back pain'],['low back','lower back']])
    value=value.replace(new RegExp(`\\b${alias}\\b`,'g'),canonical);
  return value.replace(/^(pain|tingling|numbness|stiffness|swelling) (?:in|of|at) (?:the )?(.+)$/,'$2 $1');
}
const key = (g: Pick<Group,'name'|'bodySystem'>) => `${conditionKey(g.name)}|${g.bodySystem.toLowerCase()}`;
const ids = (value: Synthesis) => [...value.groups.flatMap(g=>g.entryIDs),...value.unassigned];
function validGroup(g: Group) {
  requireValue(g && typeof g.name==='string' && g.name.trim().length>0 && [...g.name].length<=80 &&
    typeof g.reason==='string' && g.reason.trim().length>0 && [...g.reason].length<=300 &&
    systems.has(g.bodySystem) && typeof g.isPrimary==='boolean' && Array.isArray(g.entryIDs) && g.entryIDs.length>0);
  const name=normalized(g.name);
  requireValue(!/(?:^|\s)(findings?|results?|structures?)$/.test(name) &&
    !['heart','lungs','lung','bones','mediastinum','lung volume','heart size','normal','normal examination','unremarkable'].includes(name));
}
function coverage(value: Synthesis, expected: string[]) {
  requireValue(value && Array.isArray(value.groups) && Array.isArray(value.unassigned));
  value.groups.forEach(validGroup);
  const found=ids(value);
  requireValue(found.length===expected.length && new Set(found).size===found.length &&
    found.every(id=>typeof id==='string' && expected.includes(id)) &&
    value.groups.filter(g=>g.isPrimary).length<=1 && new Set(value.groups.map(key)).size===value.groups.length);
}
export function validateConditionPlan(value: unknown): ConditionPlan {
  try { return checkedConditionPlan(value); }
  catch { throw new Error('invalid_condition_workflow'); }
}
function checkedConditionPlan(value: unknown): ConditionPlan {
  const p=value as ConditionPlan;
  requireValue(p && p.version===1 && bytes(p)<=400_000 && Array.isArray(p.batches) && p.batches.length<=100 &&
    Array.isArray(p.contextEntries));
  const preserved=ids(p.preserved), candidates=p.batches.flat();
  coverage(p.preserved,preserved);
  requireValue(new Set([...preserved,...candidates.map(e=>e.id)]).size===preserved.length+candidates.length);
  const entries=[...p.contextEntries,...candidates];
  requireValue(entries.every(e=>e && typeof e.id==='string' && /^[0-9a-f-]{36}$/i.test(e.id)));
  requireValue(new Set(p.contextEntries.map(e=>e.id)).size===p.contextEntries.length &&
    p.contextEntries.every(e=>preserved.includes(e.id)) &&
    p.preserved.groups.flatMap(g=>g.entryIDs).every(id=>p.contextEntries.some(e=>e.id===id)));
  requireValue(p.batches.every(b=>Array.isArray(b) && b.length>0 && b.length<=30 && bytes({entries:b})<=24_000 &&
    b.every(e=>e.patientAssigned!==true)));
  for(const [stage,c] of [['condition-synthesis',p.mapping],['condition-verification',p.verification]] as const) {
    requireValue(c && c.response_format?.type==='json_schema');
    validatePayload({stage,...c,input:'{}'});
  }
  return structuredClone(p);
}
export function initialConditionState(plan: ConditionPlan): ConditionState {
  return {batch:0,phase:plan.batches.length?'mapping':'completed',result:structuredClone(plan.preserved),verificationIndex:0};
}
function source(entry: Entry, withID: boolean) {
  const fields=['title','details','fields','excerpt','date',...(withID?['id','category','sourceAdmission']:[])];
  return Object.fromEntries(fields.filter(k=>entry[k]!==undefined).map(k=>[k,entry[k]]));
}
function verifierInput(plan: ConditionPlan,state: ConditionState,groups: Group[]) {
  const entries=new Map([...plan.contextEntries,...plan.batches.flat()].map(e=>[e.id,e]));
  return {groups:groups.map(g=>({name:g.name,bodySystem:g.bodySystem,isPrimary:g.isPrimary,
    entries:g.entryIDs.map(id=>source(entries.get(id)!,true)),
    acceptedContext:(state.result.groups.find(old=>key(old)===key(g))?.entryIDs??[]).map(id=>source(entries.get(id)!,false))}))};
}
function localRequest(input: Record<string,any>, verification: boolean) {
  const map: Record<string,string>={};
  let count=0;
  const compact=(e: Record<string,unknown>)=>{const id=`r${++count}`;map[id]=e.id as string;return {...e,id};};
  if(verification) input.groups=input.groups.map((g:any)=>({...g,entries:g.entries.map(compact)}));
  else input.entries=input.entries.map(compact);
  return {input:JSON.stringify(input),map};
}
export function nextConditionRequest(plan: ConditionPlan,state: ConditionState): {payload:Payload;map:Record<string,string>}|null {
  if(state.phase==='completed') return null;
  const verification=state.phase==='verification';
  const input=verification?verifierInput(plan,state,state.verificationBatches![state.verificationIndex]):{
    entries:plan.batches[state.batch].map(e=>{const copy={...e};delete copy.manualReviewed;return copy;}),
    existingGroups:state.result.groups.map(g=>({name:g.name,bodySystem:g.bodySystem,isPrimary:g.isPrimary}))};
  requireValue(bytes(input)<=(verification?60_000:40_000));
  const compact=localRequest(input,verification);
  return {payload:validatePayload({stage:verification?'condition-verification':'condition-synthesis',
    ...(verification?plan.verification:plan.mapping),input:compact.input}),map:compact.map};
}
export function acceptConditionResponse(plan: ConditionPlan,previous: ConditionState,raw: string): ConditionState {
  const state=structuredClone(previous), request=nextConditionRequest(plan,state);
  requireValue(request && Buffer.byteLength(raw)<=200_000);
  const response=JSON.parse(raw);
  const restore=(value:unknown):string[]=>{
    requireValue(Array.isArray(value) && value.every(id=>typeof id==='string' && Object.hasOwn(request.map,id)));
    requireValue(new Set(value).size===value.length);
    return value.map(id=>request.map[id]);
  };
  if(state.phase==='mapping') {
    requireValue(Array.isArray(response.groups));
    // Do not accept model-supplied stable identities or per-record metadata.
    const groups:Group[]=response.groups.map((g:any)=>({name:g.name,bodySystem:g.bodySystem,
      isPrimary:g.isPrimary,reason:g.reason,entryIDs:restore(g.entryIDs)}));
    state.proposal={groups,unassigned:restore(response.unassigned)};
    coverage(state.proposal,plan.batches[state.batch].map(e=>e.id));
    state.verificationBatches=[];
    for(const group of groups) {
      const current=state.verificationBatches.at(-1);
      if(current && current.length<20 && bytes(verifierInput(plan,state,[...current,group]))<=60_000) current.push(group);
      else { requireValue(bytes(verifierInput(plan,state,[group]))<=60_000);state.verificationBatches.push([group]); }
    }
    state.result.unassigned.push(...state.proposal.unassigned);
    state.verificationIndex=0;
    state.phase='verification';
  } else {
    const groups=state.verificationBatches![state.verificationIndex];
    requireValue(Array.isArray(response.decisions) && response.decisions.length===groups.length);
    const decisions=response.decisions;
    requireValue(new Set(decisions.map(key)).size===groups.length &&
      decisions.every((d:any)=>groups.some(g=>g.name===d.name && g.bodySystem===d.bodySystem)));
    for(const group of groups) {
      const d=decisions.find((d:any)=>d.name===group.name && d.bodySystem===group.bodySystem);
      requireValue(typeof d.nameSupported==='boolean' && typeof d.reason==='string' && d.reason.trim().length>0);
      const supported=restore(d.supportedEntryIDs);
      requireValue(supported.every(id=>group.entryIDs.includes(id)));
      const kept=d.nameSupported?group.entryIDs.filter(id=>supported.includes(id)):[];
      state.result.unassigned.push(...group.entryIDs.filter(id=>!kept.includes(id)));
      if(!kept.length) continue;
      const reason=[...d.reason.trim()].slice(0,300).join('');
      const existing=state.result.groups.find(g=>key(g)===key(group));
      const reasons=kept.flatMap(id=>[id,reason]); // Swift Codable UUID-key dictionary wire format.
      if(existing) { existing.entryIDs.push(...kept);existing.entryReasons=[...(existing.entryReasons??[]),...reasons]; }
      else state.result.groups.push({...group,entryIDs:kept,reason,entryReasons:reasons,
        isPrimary:group.isPrimary && !state.result.groups.some(g=>g.isPrimary)});
    }
    state.verificationIndex++;
  }
  if(state.phase==='verification' && state.verificationIndex===state.verificationBatches!.length) {
    state.batch++;state.proposal=undefined;state.verificationBatches=undefined;state.verificationIndex=0;
    state.phase=state.batch===plan.batches.length?'completed':'mapping';
  }
  if(state.phase==='completed') coverage(state.result,[...ids(plan.preserved),...plan.batches.flat().map(e=>e.id)]);
  return state;
}
