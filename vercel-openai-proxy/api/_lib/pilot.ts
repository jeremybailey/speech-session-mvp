export function durableEnabledForOwner(owner:string):boolean {
  // Callers obtain owner from verified Kinde authentication. The shared ledger
  // budget remains the spending boundary; alpha testers need no second enrollment.
  return process.env.AI_DURABLE_ENABLED==='true' && owner.trim().length>0;
}
