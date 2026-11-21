export type SummaryTemporal={role:'event'|'ongoing'|'documented'|'unknown';start:string|null;end:string|null;approximate:boolean;sourceQuote:string|null;citationIDs:string[]};
const normalize=(s:string)=>s.replace(/\s+/gu,' ').trim().toLowerCase();
// Clinical evidence can contain JSON-encoded source passages. Compare against
// decoded string values as well as plain text, without joining unrelated fields.
function containsSourceQuote(text:string,quote:string):boolean {
 if(normalize(text).includes(quote))return true;
 for(const match of text.matchAll(/"(?:[^"\\]|\\.)*"/gu)){
  try {if(normalize(JSON.parse(match[0])).includes(quote))return true;}catch{}
 }
 return false;
}
function validDate(value:string):boolean {
 if(!/^(?:19|20)\d{2}(?:-(?:0[1-9]|1[0-2])(?:-(?:0[1-9]|[12]\d|3[01]))?)?$/.test(value))return false;
 if(value.length!==10)return true;
 const date=new Date(value+'T00:00:00Z');return !isNaN(+date)&&date.toISOString().slice(0,10)===value;
}
// Validate the supplied precision, not merely the year. A quoted year alone
// cannot justify an invented month/day during summarization.
function supportsPrecision(value:string,quote:string):boolean {
 if(value.length===4)return true;
 const dates:string[]=[];
 for(const m of quote.matchAll(/\b((?:19|20)\d{2})-(\d{2})(?:-(\d{2}))?\b/g))dates.push(m[1]+'-'+m[2]+(m[3]?'-'+m[3]:''));
 const months=['jan(?:uary)?','feb(?:ruary)?','mar(?:ch)?','apr(?:il)?','may','jun(?:e)?','jul(?:y)?','aug(?:ust)?','sep(?:t(?:ember)?)?','oct(?:ober)?','nov(?:ember)?','dec(?:ember)?'];
 const monthIndex=(name:string)=>months.findIndex(pattern=>new RegExp('^'+pattern+'$').test(name));
 for(const m of quote.matchAll(/\b([a-z]+)\s+(?:(\d{1,2})(?:st|nd|rd|th)?[,]?\s+)?((?:19|20)\d{2})\b/g)){
  const month=monthIndex(m[1]);if(month>=0)dates.push(m[3]+'-'+String(month+1).padStart(2,'0')+(m[2]?'-'+m[2].padStart(2,'0'):''));
 }
 for(const m of quote.matchAll(/\b(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]+)[,]?\s+((?:19|20)\d{2})\b/g)){
  const month=monthIndex(m[2]);if(month>=0)dates.push(m[3]+'-'+String(month+1).padStart(2,'0')+'-'+m[1].padStart(2,'0'));
 }
 return dates.some(date=>date===value||value.length===7&&date.startsWith(value+'-'));
}
export function validateSummaryTemporal(value:any,pointCitations:string[],evidence:{id:string;text:string}[]):void {
 if(!value||!['event','ongoing','documented','unknown'].includes(value.role)||typeof value.approximate!=='boolean'||!Array.isArray(value.citationIDs)||!value.citationIDs.every((id:any)=>typeof id==='string'&&pointCitations.includes(id)))throw Error('invalid_summary_temporal');
 if(value.role==='unknown'){
  if(value.start!==null||value.end!==null||value.sourceQuote!==null||value.citationIDs.length||value.approximate)throw Error('invalid_summary_temporal');return;
 }
 if(typeof value.start!=='string'||!validDate(value.start)||value.end!==null&&(typeof value.end!=='string'||!validDate(value.end)||value.end<value.start)||typeof value.sourceQuote!=='string'||!value.sourceQuote.trim()||value.sourceQuote.length>400||!value.citationIDs.length)throw Error('invalid_summary_temporal');
 const quote=normalize(value.sourceQuote);
 if(!evidence.some(e=>value.citationIDs.includes(e.id)&&containsSourceQuote(e.text,quote)))throw Error('invalid_summary_temporal');
 // A quoted date or an explicit anchored arithmetic expression must support each year.
 const supported=new Set(quote.match(/\b(?:19|20)\d{2}\b/g)??[]);
 const relative=quote.match(/\b(?:(about|approximately|around|roughly)\s+)?(\d{1,3})(?:\s*[-–—]\s*(\d{1,3}))?\s+years?\s+(before|prior to|after)\s+(?:[a-z]+\s+)?((?:19|20)\d{2})\b/);
 if(relative&&value.role!=='documented'){
  supported.clear();
  if(value.start.length!==4||value.end&&value.end.length!==4)throw Error('invalid_summary_temporal');
  const direction=relative[4]==='after'?1:-1;const anchor=Number(relative[5]);
  supported.add(String(anchor+direction*Number(relative[2])));supported.add(String(anchor+direction*Number(relative[3]??relative[2])));
  if(relative[1]&&!value.approximate)throw Error('invalid_summary_temporal');
 }
 if(!supported.has(value.start.slice(0,4))||value.end&&!supported.has(value.end.slice(0,4))||!supportsPrecision(value.start,quote)||value.end&&!supportsPrecision(value.end,quote))throw Error('invalid_summary_temporal');
}

// Date labels are optional presentation metadata. An unsupported label must not
// invalidate otherwise valid clinical points or spend another provider call.
// Keep all source/citation/content validation in the caller; fail closed on time.
export function supportedSummaryTemporal(value:unknown,pointCitations:string[],evidence:{id:string;text:string}[]):SummaryTemporal {
 try {validateSummaryTemporal(value,pointCitations,evidence);return value as SummaryTemporal;}
 catch {return {role:'unknown',start:null,end:null,approximate:false,sourceQuote:null,citationIDs:[]};}
}
