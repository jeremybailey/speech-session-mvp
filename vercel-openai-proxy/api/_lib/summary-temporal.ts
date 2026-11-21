export type SummaryTemporal={role:'event'|'ongoing'|'documented'|'unknown';start:string|null;end:string|null;approximate:boolean;sourceQuote:string|null;citationIDs:string[]};
const normalize=(s:string)=>s.replace(/\s+/gu,' ').trim().toLowerCase();
function validDate(value:string):boolean {
 if(!/^(?:19|20)\d{2}(?:-(?:0[1-9]|1[0-2])(?:-(?:0[1-9]|[12]\d|3[01]))?)?$/.test(value))return false;
 if(value.length!==10)return true;
 const date=new Date(value+'T00:00:00Z');return !isNaN(+date)&&date.toISOString().slice(0,10)===value;
}
export function validateSummaryTemporal(value:any,pointCitations:string[],evidence:{id:string;text:string}[]):void {
 if(!value||!['event','ongoing','documented','unknown'].includes(value.role)||typeof value.approximate!=='boolean'||!Array.isArray(value.citationIDs)||!value.citationIDs.every((id:any)=>typeof id==='string'&&pointCitations.includes(id)))throw Error('invalid_summary_temporal');
 if(value.role==='unknown'){
  if(value.start!==null||value.end!==null||value.sourceQuote!==null||value.citationIDs.length||value.approximate)throw Error('invalid_summary_temporal');return;
 }
 if(typeof value.start!=='string'||!validDate(value.start)||value.end!==null&&(typeof value.end!=='string'||!validDate(value.end)||value.end<value.start)||typeof value.sourceQuote!=='string'||!value.sourceQuote.trim()||value.sourceQuote.length>400||!value.citationIDs.length)throw Error('invalid_summary_temporal');
 const quote=normalize(value.sourceQuote);
 if(!evidence.some(e=>value.citationIDs.includes(e.id)&&normalize(e.text).includes(quote)))throw Error('invalid_summary_temporal');
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
 if(!supported.has(value.start.slice(0,4))||value.end&&!supported.has(value.end.slice(0,4)))throw Error('invalid_summary_temporal');
}
