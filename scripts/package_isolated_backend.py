#!/usr/bin/env python3
"""Package an isolated backend without changing its public API or the pilot deployment."""
import argparse,json,shutil,os
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('destination',type=Path);a=p.parse_args();target=a.destination.resolve()
assert target!=root and target!=root/'vercel-openai-proxy'
link=target/'.vercel/project.json'
if link.exists():assert json.loads(link.read_text()).get('projectName')=='collectivecare-fork-b-recovery-test'
source=root/'vercel-openai-proxy'
# These are generated files in the explicitly selected isolated checkout.
for directory in ['api','server']:
 if (target/directory).exists():shutil.rmtree(target/directory)
shutil.copytree(source/'api',target/'server')
(target/'api').mkdir(parents=True)
shutil.copytree(source/'scripts',target/'scripts',dirs_exist_ok=True)
for script in (target/'scripts').glob('*.ts'):
 script.write_text(script.read_text().replace('../api/','../server/'))
configuration=json.loads((source/'vercel.json').read_text());queue_paths={p for p,c in configuration['functions'].items() if c.get('experimentalTriggers')}
imports=[];routes=[]
for i,path in enumerate(sorted((source/'api').rglob('*.ts'))):
 relative=path.relative_to(source)
 if '_lib' in relative.parts:continue
 if str(relative) in queue_paths:
  destination=target/relative;destination.parent.mkdir(parents=True,exist_ok=True)
  module=os.path.relpath(target/'server'/path.relative_to(source/'api'),destination.parent).removesuffix('.ts')
  destination.write_text('export {default} from '+json.dumps(module)+';\n')
 else:
  route='/'+str(relative.with_suffix(''))
  module='../server/'+str(path.relative_to(source/'api').with_suffix(''))
  imports.append('import * as route'+str(i)+' from '+json.dumps(module)+';')
  routes.append(json.dumps(route)+':route'+str(i))
router='''import type {VercelRequest,VercelResponse} from '@vercel/node';
IMPORTS
export const config={api:{bodyParser:false}};
const routes:Record<string,{default:(req:VercelRequest,res:VercelResponse)=>unknown;config?:{api?:{bodyParser?:unknown}}}>={ROUTES};
export default async function handler(req:VercelRequest,res:VercelResponse){
 const selected=req.query.__cc_route;
 if(typeof selected!=='string')return res.status(404).end();
 const route=routes['/api/'+selected];
 if(!route)return res.status(404).end();
 delete req.query.__cc_route;
 if(route.config?.api?.bodyParser!==false&&req.method!=='GET'&&req.method!=='HEAD'){
  const chunks:Buffer[]=[];let length=0;
  try{
   for await(const chunk of req){const bytes=Buffer.from(chunk);length+=bytes.length;if(length>4_500_000)return res.status(413).end();chunks.push(bytes);}
   const body=Buffer.concat(chunks).toString('utf8');
   req.body=body?JSON.parse(body):{};
  }catch{return res.status(400).json({error:'invalid_json'});}
 }
 return route.default(req,res);
}
'''.replace('IMPORTS','\n'.join(imports)).replace('ROUTES',','.join(routes))
(target/'api/index.ts').write_text(router)
shutil.copy2(root/'scripts/isolated-router-smoke.ts',target/'scripts/router-smoke.ts')
configuration['functions']={p:c for p,c in configuration['functions'].items() if p in queue_paths}
configuration['functions']['api/index.ts']={'maxDuration':300}
configuration['routes']=[{'src':'/(server|scripts|migrations|tests|node_modules)(/.*)?','status':404},{'handle':'filesystem'},{'src':'/api/(.*)','dest':'/api/index?__cc_route=$1'},{'src':'/.*','status':404}]
(target/'vercel.json').write_text(json.dumps(configuration,indent=2)+'\n')
(target/'.vercelignore').write_text('node_modules\n.env*\ntests\nscripts/bootstrap-isolated.ts\nscripts/router-smoke.ts\nscripts/readiness-*.ts\n')
print('Packaged',len(routes),'public routes and',len(queue_paths),'private queue consumers into',1+len(queue_paths),'functions.')
