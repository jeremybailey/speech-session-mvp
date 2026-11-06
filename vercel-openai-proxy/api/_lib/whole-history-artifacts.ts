/** Sparse category fields within the existing B request, replacing prose inventory. */
import {structuredMedicationTemplate} from './whole-history-medications';
export const artifactVersion='structured-artifacts-v3';
export const artifactFields:Record<string,string[]>={
 practitionerContact:['name','organization','role','phone','email','address','context'],
 chiefComplaint:['name','location','onset','duration','severity','frequency','context'],
 symptoms:['name','location','onset','duration','severity','frequency','context'],
 findings:['name','result','location','interpretation','context'],
 testsAndLabs:['name','result','units','referenceRange','specimen','interpretation','context'],
 allergies:['name','reaction','severity','recordStatus','context'],
 vaccinations:['name','dose','route','site','lot','recordStatus','context'],
 biopsychosocialContext:['name','context'],otherNotes:['name','context']};
/** v7 uses category-scoped objects; earlier persisted pair arrays remain valid. */
export function artifactPairs(value:any,category:string):string[][]|null|undefined {
 const allowed=artifactFields[category];
 if(!allowed)return value===null?null:undefined;
 let pairs:any=value;
 if(Array.isArray(value)&&value.some(p=>p&&typeof p==='object'&&!Array.isArray(p))){
  if(!value.every(p=>p&&typeof p==='object'&&!Array.isArray(p)&&Object.keys(p).sort().join('|')==='key|value'))return undefined;
  pairs=value.map(p=>[p.key,p.value]);
 }
 if(value&&typeof value==='object'&&!Array.isArray(value)) {
  if(Object.keys(value).some(key=>key.startsWith('_pad'))){
   const padding=Array.from({length:7-allowed.length},(_,i)=>'_pad'+(i+1));
   if(Object.keys(value).sort().join('|')!==[...allowed,...padding].sort().join('|')||!padding.every(key=>value[key]===null))return undefined;
   value=Object.fromEntries(allowed.map(key=>[key,value[key]]));
  }
  if(Object.keys(value).sort().join('|')!==[...allowed].sort().join('|')||!Object.values(value).every(v=>v===null||typeof v==='string'))return undefined;
  pairs=allowed.filter(k=>value[k]!==null).map(k=>[k,value[k]]);
 }
 if(!Array.isArray(pairs)||pairs.length>12||!pairs.every(p=>Array.isArray(p)&&p.length===2&&typeof p[0]==='string'&&allowed.includes(p[0])&&typeof p[1]==='string'&&p[1].trim()&&Array.from(p[1]).length<=360)||!validFieldMultiplicity(pairs,category))return undefined;
 return pairs;
}
/** Context annotations are repeatable source fragments, never scalar result/dose pairs.
 * An aggregate finding may also name several distinct observations. */
export function validFieldMultiplicity(pairs:string[][],category:string):boolean {
 const seen=new Set<string>();const repeated=new Set<string>();
 for(const [key,value] of pairs){
  const repeatable=key==='context'||(category==='findings'&&key==='name');
  const identity=JSON.stringify([key,value]);
  if(seen.has(key)&&!(repeatable&&!repeated.has(identity)))return false;
  seen.add(key);repeated.add(identity);
 }
 return true;
}
export function validArtifact(value:any,category:string):boolean {return artifactPairs(value,category)!==undefined;}
export function groundedArtifact(values:string[][],sources:string[]):string[][] {
 const norm=(s:string)=>s.normalize('NFKC').toLowerCase().trim().replace(/\s+/g,' ');
 return values.filter(p=>sources.some(s=>norm(s).includes(norm(p[1]))));
}
export function structuredArtifactTemplate(base:any){
 const template=structuredMedicationTemplate(base);template.version=artifactVersion;
 template.schema.$defs.artifactFields={anyOf:[{type:'null'},{type:'array',maxItems:12,items:{type:'array',minItems:2,maxItems:2,items:{type:'string',maxLength:360}}}]};
 for(const v of template.schema.$defs.fact.anyOf){v.properties.f={$ref:'#/$defs/artifactFields'};v.required.push('f');}
 template.instructions+=`
SPARSE CATEGORY STRUCTURE v3: f is a sparse array of [fieldCode, exact source value] pairs; omit absent values. Copy each value literally from the row's primary/context passages. No duplicate field codes. Allowed fields by category: ${JSON.stringify(artifactFields)}. f is null for medications/carePlan/followUp (their m/p contracts are unchanged). For other categories f must be an array, possibly empty. Name is a short identity, never a sentence. Contacts: exactly one person OR organization per row; name is the person/organization, role is an explicitly stated role/specialty, organization/phone/email/address must explicitly belong to that entity. Shared clinic channels belong to the organization, not each listed doctor. Separate printed names do not establish which doctor prescribed, treated or owns a plan. Unknown prescriber remains unknown in context. Never classify the patient as a care-team provider. Preserve ambiguous names/roles without guessing. Include every stated contact field even if clinically peripheral. Copy complete postal addresses, preserving suite, street, city, region and postal code; no missing-value boilerplate or inferred country. Labs: name/result/units/referenceRange are separate. Vaccination recordStatus must distinguish dispensed from administered. Allergy reaction, negation, uncertainty and source-qualified status stay explicit. Clinical qualifiers, conditionality, severity, laterality, timeline and ownership must not disappear. For f-array categories only, v[0] now carries only the concise fact statement and clinically material qualifiers not already expressed in f; do not narrate the name, organization, address, phone and field inventory a second time. Do not replace a clinical qualifier with an unsupported short name. Full original passages are already retained by reference. This replaces repetitive prose; do not add a summary, second pass or additional output sections.
`;
 return template;
}
