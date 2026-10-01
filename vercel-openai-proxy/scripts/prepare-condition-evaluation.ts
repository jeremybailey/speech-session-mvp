// Offline only. Contract input is exported from compiled Swift production code.
import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {evaluationPlan,EvaluationCase} from './condition-evaluation';

async function main() {
  const [contractPath,outputPath]=process.argv.slice(2);
  if(!contractPath || !outputPath) throw new Error('Usage: prepare-condition-evaluation.ts contracts.json output.json');
  const contracts=JSON.parse(await readFile(contractPath,'utf8'));
  const fixtures:EvaluationCase[]=[];
  for(const file of ['evaluation.json','context-evaluation.json']) fixtures.push(...JSON.parse(await readFile(`../Tests/Fixtures/ConditionSynthesis/${file}`,'utf8')));
  const cases=fixtures.map(fixture=>({fixture,plan:evaluationPlan(fixture,contracts)}));
  const digest=createHash('sha256').update(JSON.stringify(cases)).digest('hex');
  await writeFile(outputPath,JSON.stringify({version:1,digest,cases}));
  console.log(JSON.stringify({cases:cases.length,contractDigest:digest,paidRequests:0}));
}
main().catch(error=>{console.error(error instanceof Error?error.message:'evaluation_preparation_failed');process.exitCode=1;});
