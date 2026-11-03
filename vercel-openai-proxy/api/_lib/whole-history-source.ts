/** Exact port of compact-actions-v1 source partitioning. Source-only input. */
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
export function makePayload(records:unknown,template:any,structuredMedications=false){
 if(structuredMedications)template=structuredMedicationTemplate(template);
 const {source,table}=makeBundle(records,template);const schema=structuredClone(template.schema);
 schema.$defs.sourceRef.enum=Object.keys(table);
 schema.properties.passages.properties=Object.fromEntries(Object.keys(table).map(id=>[id,structuredClone(template.passageSchema)]));
 schema.properties.passages.required=Object.keys(table);
 const payload={stage:'whole-history-generation',instructions:template.instructions,input:JSON.stringify(source),response_format:{type:'json_schema',json_schema:{name:'paired_source_compact_actions',strict:true,schema}}};
 if(Buffer.byteLength(JSON.stringify(payload))+4096+64000>1050000||Buffer.byteLength(JSON.stringify(payload))>1900000)throw Error('context_limit_exceeded');
 return {payload,table};
}
