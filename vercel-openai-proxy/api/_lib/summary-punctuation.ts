/** Presentation-only splitting, matching the app's share bullet rendering.
 * Retain every qualifier and repeat the topic, never shorten clinical content. */
export function splitHandoffItems(text:string):string[] {
 const separator=text.indexOf(' — ');
 if(separator<0)return [text];
 const prefix=text.slice(0,separator+3),value=text.slice(separator+3);
 let quote='',depth=0,start=0;const items:string[]=[];
 for(let i=0;i<value.length;i++){
  const c=value[i];
  if(quote){if(c===quote)quote='';continue;}
  if(c==='“')quote='”';else if(c==='"')quote='"';
  else if(c==='('||c==='[')depth++;
  else if(c===')'||c===']')depth=Math.max(0,depth-1);
  else if(c===';'&&depth===0){items.push(value.slice(start,i).trim());start=i+1;}
 }
 if(!items.length)return [text];
 items.push(value.slice(start).trim());
 if(items.some(item=>!item))return [text];
 return items.map(item=>prefix+item);
}
