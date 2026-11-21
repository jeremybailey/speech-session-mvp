// Expose only known safe error codes, never exception text or request contents.
export function storyOperationFailure(error:unknown):{status:number;code:string} {
 const failure=error as {message?:string;status?:number};
 if(failure?.status===401)return {status:401,code:'authentication_required'};
 if(failure?.message==='budget_exhausted')return {status:429,code:'budget_exhausted'};
 if(failure?.message==='revision_conflict')return {status:409,code:'revision_conflict'};
 if(failure?.message?.startsWith('invalid'))return {status:422,code:'invalid_request'};
 return {status:503,code:'operation_unavailable'};
}
