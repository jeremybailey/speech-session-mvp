type ProgressStep={key:string;state:string;repair?:boolean};
export function summaryActivity(state:string,steps:ProgressStep[]):string {
 if(state==='completed')return 'Finishing up';
 if(state==='retry_scheduled')return 'Waiting briefly';
 if(state==='needs_attention')return 'Needs attention';
 const running=steps.filter(s=>s.state==='running');
 // Several batches can run together. Show the earliest active phase consistently.
 const labels:string[]=running.map(s=>s.repair?'Refining wording':s.key.startsWith('final:')?(s.key.endsWith(':check')?'Final checks':'Writing summary'):s.key.startsWith('draft:')?'Reading records':s.key.startsWith('audit:')?'Reviewing coverage':s.key.endsWith(':check')||s.key.startsWith('check:')?'Checking sources':s.key.startsWith('merge:')?'Combining notes':'Preparing summary');
 return ['Reading records','Checking sources','Combining notes','Reviewing coverage','Writing summary','Final checks','Refining wording'].find(label=>labels.includes(label))??'Preparing summary';
}
