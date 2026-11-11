// Only expose the answer text from a still-incomplete structured response.
// Drafts are transient UI previews, never accepted facts or conversation history.
export function storyDraftText(json:string):string | undefined {
 const match=json.match(/"text"\s*:\s*("(?:[^"\\]|\\.)*)/s);
 if(!match)return;
 try {return JSON.parse(match[1]+'"');}catch{return;}
}
