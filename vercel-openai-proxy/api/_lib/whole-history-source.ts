/** Exact port of compact-actions-v1 source partitioning. Source-only input. */
import {structuredPlanTemplate,briefPlanTemplate,careTitleTemplate,strictCareTemplate,categoryCareTemplate,balancedCategoryTemplate,uniformCategoryTemplate} from './whole-history-plans';
import {structuredArtifactTemplate} from './whole-history-artifacts';
import {structuredMedicationTemplate} from './whole-history-medications';
import { createHash } from 'node:crypto';
export type Original={id:string;text:string;date?:string;title?:string;sourceReference?:string;sourceSHA256?:string};
export function makeBundle(values:unknown,template:any){
 if(!Array.isArray(values)||!values.length||values.length>1000)throw Error('invalid_records');
 const ids=new Set<string>();const table:Record<string,any>={};const originals:any[]=[];
 for(const [i,r] of values.entries()){
  if(!r||typeof r.id!=='string'||! /^[0-9a-f-]{36}$/i.test(r.id)||ids.has(r.id)||typeof r.text!=='string'||!r.text.trim())throw Error('invalid_records');ids.add(r.id);
  for(const k of ['date','title','sourceReference'])if(r[k]!==undefined&&(typeof r[k]!=='string'||r[k].length>1000))throw Error('invalid_records');
  const hash=createHash('sha256').update(r.text).digest('hex');if(r.sourceSHA256&&r.sourceSHA256!==hash)throw Error('source_hash_mismatch');
  const chars=Array.from(r.text as string),chunks:any[]=[];let start=0;
  while(start<chars.length){let end=Math.min(start+440,chars.length);
   if(end<chars.length){const part=chars.slice(start,end).join('');const ends=[...part.matchAll(/[.!?][ \t\r\n]+|\n+/g)].map(m=>Array.from(part.slice(0,m.index!+m[0].length)).length).filter(n=>n>=160);
    if(ends.length)end=start+ends[ends.length-1];else{let space=-1;for(let x=start+160;x<end;x++)if(chars[x]===' ')space=x;if(space>=0)end=space+1;}}
   chunks.push({start,end,text:chars.slice(start,end).join('')});start=end;
  }
  const alias=`r${i+1}`,passages:any[]=[];
  for(let j=0;j<chunks.length;j+=2){const pair=chunks.slice(j,j+2),id=`${alias}.p${passages.length+1}`,quote=pair.map(x=>x.text).join('');passages.push({id,text:quote});table[id]={recordID:r.id,recordAlias:alias,start:pair[0].start,end:pair.at(-1).end,quote,sourceSHA256:hash,sourceReference:r.sourceReference??''};}
  originals.push({r:alias,originalID:r.id,savedDate:r.date??'',title:r.title??'',sourceReference:r.sourceReference??'',sourceSHA256:hash,passages});
 }
 const source={version:template.version,originalRecords:originals,coreColumns:template.coreColumns,appCategoryPolicy:template.appCategoryPolicy,organizationVocabulary:template.organizationVocabulary};
 if(Object.keys(table).length>700)throw Error('too_many_passages');
 return {source,table};
}
/** Reject unsupported provider schemas before reserving budget or dispatching. */
export function assertProviderSchemaLimits(schema:any){
 let properties=0,enums=0,strings=0;
 const walk=(node:any)=>{
  if(!node||typeof node!=='object')return;
  if(node.properties){const names=Object.keys(node.properties);properties+=names.length;strings+=names.reduce((n,k)=>n+k.length,0);}
  if(node.$defs)strings+=Object.keys(node.$defs).reduce((n,k)=>n+k.length,0);
  if(Array.isArray(node.enum)){
   enums+=node.enum.length;
   const length=node.enum.reduce((n:number,v:any)=>n+(typeof v==='string'?Array.from(v).length:0),0);strings+=length;
   if(node.enum.length>250&&length>15000)throw Error('context_limit_exceeded');
  }
  if(typeof node.const==='string')strings+=Array.from(node.const).length;
  for(const value of Object.values(node))walk(value);
 };
 walk(schema);
 if(properties>5000||enums>1000||strings>120000)throw Error('context_limit_exceeded');
}
export function makePayload(records:unknown,template:any,structuredMedications=false,structuredArtifacts=false,aggregatePlans=false,briefPlans=false,careTitles=false,strictArtifacts=false,categorySemantics=false,balancedCategories=false,uniformFields=false){
 if(uniformFields)template=uniformCategoryTemplate(template);
 else if(balancedCategories)template=balancedCategoryTemplate(template);
 else if(categorySemantics)template=categoryCareTemplate(template);
 else if(strictArtifacts)template=strictCareTemplate(template);
 else if(careTitles)template=careTitleTemplate(template);
 else if(briefPlans)template=briefPlanTemplate(template);
 else if(aggregatePlans)template=structuredPlanTemplate(template);
 else if(structuredArtifacts)template=structuredArtifactTemplate(template);
 else if(structuredMedications)template=structuredMedicationTemplate(template);
 const {source,table}=makeBundle(records,template);const schema=structuredClone(template.schema);
 schema.$defs.sourceRef.enum=Object.keys(table);
 // Apply the app's fact limit and context scope before generation.
 if(categorySemantics){
  for(const fact of schema.$defs.fact.anyOf){
   fact.properties.v.items.maxLength=Math.min(fact.properties.v.items.maxLength,360);
   const categories=fact.properties.k.enum;
   if(!categories.some((category:string)=>['carePlan','followUp','vaccinations','medications','testsAndLabs','practitionerContact'].includes(category)))fact.properties.p={type:'null'};
  }
  // Share field definitions; the provider only resolves named $defs references.
  for(const [index,variant] of schema.$defs.fact.anyOf.entries()){
   for(const key of Object.keys(variant.properties)){
    if(key==='c')continue;
    const name=`fact_${index}_${key}`;
    schema.$defs[name]=variant.properties[key];
    variant.properties[key]={$ref:'#/$defs/'+name};
   }
  }
  // v19 restores record-scoped context references. Reject schemas over provider
  // limits before charging; never silently widen the source scope to fit.
  for(const record of (balancedCategories&&!uniformFields?[]:source.originalRecords)){
   const sourceName='source_'+record.r;
   schema.$defs[sourceName]={type:'string',enum:record.passages.map((p:any)=>p.id)};
   const facts=structuredClone(schema.$defs.fact);
   for(const variant of facts.anyOf)variant.properties.c.items={$ref:'#/$defs/'+sourceName};
   schema.$defs['fact_'+record.r]=facts;
  }
 }
 schema.properties.passages.properties=Object.fromEntries(Object.keys(table).map(id=>{
  const passage=structuredClone(template.passageSchema);
  if(categorySemantics&&(!balancedCategories||uniformFields))passage.anyOf.find((v:any)=>v.type==='array').items={$ref:'#/$defs/fact_'+table[id].recordAlias};
  return [id,passage];
 }));
 schema.properties.passages.required=Object.keys(table);
 assertProviderSchemaLimits(schema);
 const instructions=template.instructions+'\nFINAL REFERENCE AUDIT: Each fact row belongs to its enclosing passage. Its c array may contain only passage IDs from that SAME original record alias (rN); use [] when no same-record context is needed. Cross-record links belong in shared concern IDs in g, never c. Declare each concern ID exactly once; never repeat an ID in a fact row g array. Every concern declared in concerns must appear in at least one fact row g array, and every g value must name a declared concern. Audit these references before returning the single response.';
 const payload={stage:'whole-history-generation',instructions,input:JSON.stringify(source),response_format:{type:'json_schema',json_schema:{name:'paired_source_compact_actions',strict:true,schema}}};
 if(Buffer.byteLength(JSON.stringify(payload))+4096+64000>1050000||Buffer.byteLength(JSON.stringify(payload))>1900000)throw Error('context_limit_exceeded');
 return {payload,table};
}
