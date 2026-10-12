import {spawnSync} from 'node:child_process';
// Fail rather than silently skipping persistence coverage. This suite initializes
// a dedicated empty database and must never point at a production service.
const value=process.env.AI_WORKFLOW_TEST_DATABASE_URL;
let url;
try {url=new URL(value??'');} catch {throw new Error('Set AI_WORKFLOW_TEST_DATABASE_URL to an empty local cc_test_* database.');}
if(!['postgres:','postgresql:'].includes(url.protocol) || !['localhost','127.0.0.1','[::1]'].includes(url.hostname) || !url.pathname.startsWith('/cc_test_'))
 throw new Error('Recovery tests require an empty local cc_test_* database. Remote databases are forbidden.');
const result=spawnSync(process.execPath,['--import','tsx','--test','tests/condition-contract.test.ts','tests/condition-workflow.test.ts'],{stdio:'inherit',env:process.env});
if(result.error) throw result.error;
process.exit(result.status??1);
