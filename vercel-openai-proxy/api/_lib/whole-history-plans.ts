/** Plan identity and concise action wording in the existing generation call. */
import {structuredArtifactTemplate,artifactFields} from './whole-history-artifacts';
export const planVersion='structured-plans-v4';
export function validPlan(p:any,category:string):boolean {
 if(p===null)return true;
 if(!p||typeof p!=='object'||Array.isArray(p)||!Object.values(p).every(v=>typeof v==='string'&&Array.from(v).length<=1000))return false;
 const keys=Object.keys(p).sort().join('|');
 if(keys==='a|q|t')return true;
 return keys==='a|h|i|q|t'&&['carePlan','followUp'].includes(category)&&/^p[1-9]\d{0,3}$/.test(p.i)&&Array.from(p.h).length<=80;
}
export function structuredPlanTemplate(base:any){
 const template=structuredArtifactTemplate(base);template.version=planVersion;
 for(const v of template.schema.$defs.fact.anyOf){
  if(v.properties.k.enum.some((k:string)=>['carePlan','followUp'].includes(k))){
   v.properties.p.properties.i={type:'string',pattern:'^p[1-9]\\d{0,3}$',maxLength:5};
   v.properties.p.properties.h={type:'string',maxLength:80};
   v.properties.p.required.push('i','h');
   v.properties.v.items.maxLength=160;
  }
 }
 template.instructions+=`
SHARED CARE PLAN ENTITY v4: For carePlan/followUp rows p contains existing a (next-step owner), t (timing), q (material conditionality/uncertainty), plus i (record-local plan ID p1, p2, ...) and h (short plan title, up to 80 characters). Use one plan ID for aggregate advice from the same source encounter/provider, linked to all relevant existing concerns. Multiple linked conditions do not create duplicate plans. Different encounters, providers, conflicting clinical dates, or explicitly separate plans require distinct IDs. Never combine fictional/role-play material with actual patient advice. IDs are local to each original record. Supply h on the first row of that plan; use an empty h on subsequent rows. No extra top-level plans array is needed.
For these action rows, v[0] is now a concise patient-readable action, aiming at 6–16 words and at most 160 characters. Replace verbose 'Clinician recommends/advises...' framing with the action itself. This is faithful summarisation of source advice, never new advice. Preserve negation, dose, laterality and every safety-critical qualifier. Put stated timing once in t, next-step owner only in a, and material conditions/uncertainty once in q; do not concatenate or restate them inside each field. Do not put explanatory physiology, repetitive reasoning, transcript narration or provenance in the action. The original passages are retained for those details. Preserve 'if', 'unless', 'consider', 'perhaps' and declined/past/uncertain state; conditional advice cannot become an unconditional current task. Medication instructions must retain all required dose/frequency/route constraints; never invent or simplify these away. Keep actions, follow-up and considerations distinct. Repeated genuinely equivalent advice within the same plan should use consistent concise action wording and the same t/q/a so the app can coalesce exact repeats while preserving every source occurrence. Distinct timings, qualifications, patient decisions and meaning remain distinct. Each source passage still receives its required grounded rows. Do not drop clinical content to meet the wording target; preserve material qualifiers in t/q or separate distinct actions. This replaces long form action prose within this existing response, not a new summarisation pass. Non-action rows and their f/m contracts are unchanged.
`;
 return template;
}

/** New runs only: preserve the exact v4 payload for already pending work. */
export const briefPlanVersion='structured-plans-brief-v5';
export function briefPlanTemplate(base:any){
 const template=structuredPlanTemplate(base);template.version=briefPlanVersion;
 template.instructions+=`
BRIEF CARE WORDING v5: Prefer 4–9 words per action, rather than the earlier 6–16-word aim. Use the shortest complete verb-led instruction that preserves its meaning. Use a 3–6-word plan title. Timing and material conditions should be short phrases, normally 2–8 words; omit restatements of the action and explanatory reasoning. Do not repeat the condition name, practitioner attribution, next-step owner, schedule or explanation across title, action, t and q. The next-step owner remains in a when explicitly stated, for routing, but is not displayed as an owner line. Keep a recipient in the action when essential (for example whom to contact). Preserve dose, frequency, laterality, negation, uncertainty, conditionality and action sequence; a short target never permits dropping these. Use a longer phrase within the existing limits when necessary. Full explanations and source wording remain in the original record. This is shorter wording inside the same response, not another summary or processing pass.
`;
 return template;
}

export const careTitleVersion='structured-care-titles-v6';
export function careTitleTemplate(base:any){
 const template=briefPlanTemplate(base);template.version=careTitleVersion;
 template.instructions+=`
CARE-FOCUSED TITLES v6: h names the care this plan recommends, not the patient's diagnosis, symptom, condition label or source narrative. Use 3–6 plain words describing the main source-backed interventions or care activities. Do not copy a condition name, add 'reported' history wording, repeat provenance/scenario labels or merely append 'care plan' to a diagnosis. Select care activities from the actions themselves; do not invent a treatment, outcome or priority. Keep related conditions in g, not the title. If the record supports only a follow-up, use a review/next-steps title; if care is exploratory or declined, preserve that meaning rather than implying a definite treatment. All earlier action, timing, clinical qualifier and source-reference rules remain unchanged. This is the same h field in the same response, not an extra pass.
`;
 return template;
}

/** Opt-in contract for new app builds; no changes to older pending payloads. */
export const strictArtifactVersion='structured-artifact-objects-v7';
export function strictCareTemplate(base:any){
 const template=careTitleTemplate(base);template.version=strictArtifactVersion;
 template.schema.$defs.fact.anyOf=template.schema.$defs.fact.anyOf.flatMap((variant:any)=>variant.properties.k.enum.map((category:string)=>{
  const v=structuredClone(variant);v.properties.k.enum=[category];
  const keys=artifactFields[category];
  v.properties.f=keys?{type:'object',additionalProperties:false,required:keys,properties:Object.fromEntries(keys.map(k=>[k,{type:['string','null'],minLength:1,maxLength:360}]))}:{type:'null'};
  return v;
 }));
 template.instructions+='\nCATEGORY FIELD OBJECTS v7: This replaces the earlier f pair-array encoding only. f now uses the exact category-specific object in the response schema. Use null for absent field values, and null for the entire f on medications/carePlan/followUp. Never move a field from another category into this object. Keep clinically material information that has no corresponding field in the concise v[0] fact statement (or the existing m/p fields where applicable); do not omit it or misclassify the fact to fit a field. Every non-null f value must still be copied literally from its cited source. All source, attribution, qualifiers and plan rules remain in force. No additional processing pass.';
 return template;
}
