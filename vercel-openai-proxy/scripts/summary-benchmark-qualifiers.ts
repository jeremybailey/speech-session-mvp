/** Conservative regression probes for the fictional corpus, not a clinical evaluator. */
export function qualifierRegressions(before:string,after:string):string[]{
 const rules:[string,RegExp,RegExp][]=[
 ['vitamin-k-preference',/vitamin k[^\n]*(?:tentative|think|okay|consider)|(?:tentative|think|okay|consider)[^\n]*vitamin k/i,/vitamin k[^\n]*(?:tentative|think|okay|consider)|(?:tentative|think|okay|consider)[^\n]*vitamin k/i],
 ['sweep-declined',/(?:declin[^\n]*sweep|sweep[^\n]*declin)/i,/(?:declin[^\n]*sweep|sweep[^\n]*declin)/i],
 ['sweep-reconsideration',/(?:reconsider[^\n]*sweep|sweep[^\n]*reconsider)/i,/(?:reconsider[^\n]*sweep|sweep[^\n]*(?:reconsider|next week|later))/i],
 ['budesonide-unstarted',/(?:budesonide[^\n]*(?:not.{0,20}start|unstarted|pending|yet to start)|not.{0,20}start[^\n]*budesonide)/i,/(?:budesonide[^\n]*(?:not.{0,20}start|unstarted|pending|yet to start)|not.{0,20}start[^\n]*budesonide)/i],
 ['montelukast-stopped',/(?:montelukast[^\n]*(?:stop|discontinu)|(?:stop|discontinu)[^\n]*montelukast)/i,/(?:montelukast[^\n]*(?:stop|discontinu)|(?:stop|discontinu)[^\n]*montelukast)/i],
 ['mri-conditional',/MRI[^\n]*(?:defer|unless|if |conditional)|(?:defer|unless|conditional)[^\n]*MRI/i,/MRI[^\n]*(?:defer|unless|if |conditional|persist)|(?:defer|unless|conditional)[^\n]*MRI/i],
 ['penicillin-anaphylaxis',/penicillin[^\n]*anaphyla|anaphyla[^\n]*penicillin/i,/penicillin[^\n]*anaphyla|anaphyla[^\n]*penicillin/i],
 ['ldl-improvement',/LDL[^\n]*(?:improv|down|decreas|lower|↓)/i,/LDL[^\n]*(?:improv|down|decreas|lower|↓)/i]
 ];
 return rules.filter(([,required,preserved])=>required.test(before)&&!preserved.test(after)).map(([name])=>name);
}
