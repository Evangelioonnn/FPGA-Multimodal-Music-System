"""File-integrity and project-reference check; no simulation/build/programming."""
from pathlib import Path
import argparse,hashlib,json,re,xml.etree.ElementTree as ET
P=Path(__file__).resolve().parents[1]
a=argparse.ArgumentParser();a.add_argument('--source-only',action='store_true');a.add_argument('--strict-binaries',action='store_true');q=a.parse_args()
v=json.loads((P/'VERSION.json').read_text(encoding='utf8'));checked=0;skipped=0;listed=set()
for line in (P/'SHA256SUMS.txt').read_text(encoding='utf8').splitlines():
 expected,n=line.split('  ',1);f=P/n
 assert n not in listed,n
 listed.add(n)
 assert f.resolve().is_relative_to(P.resolve()),n
 if not f.is_file():
  if q.source_only and n.startswith('bin/')and f.suffix in ['.fs','.hex','.bin','.elf','.apk']:skipped+=1;continue
  raise AssertionError('Missing packaged file: '+n)
 assert hashlib.sha256(f.read_bytes()).hexdigest()==expected,('File changed',n)
 checked+=1
for project in [P/v['main60k']['project'],P/v['vision20k']['project']]:
 files=ET.parse(project).findall('.//File')
 for e in files:
  f=(project.parent/e.get('path')).resolve();assert f.is_relative_to(project.parent.resolve())and f.is_file(),(project.name,e.get('path'))
 print(project.name,len(files),'references present')
for family in ['main60k','vision20k']:
 d=P/v[family]['directory']
 for n,h in v[family]['source_files'].items():assert hashlib.sha256((d/n).read_bytes()).hexdigest()==h,n
 assert any(re.search(r'\bmodule\s+'+re.escape(v[family]['Top'])+r'\b',f.read_text(encoding='utf8')) for f in d.rglob('*.v')),'Top module missing'
for n,h in v['binary_files'].items():
 f=P/n
 if not f.is_file() and q.source_only:continue
 assert f.is_file() and hashlib.sha256(f.read_bytes()).hexdigest()==h,n
actual={f.relative_to(P).as_posix() for f in P.rglob('*') if f.is_file() and '.git' not in f.relative_to(P).parts}
assert not(actual-listed-{'SHA256SUMS.txt'}),('Unlisted files',sorted(actual-listed-{'SHA256SUMS.txt'}))
print('Package integrity passed:',checked,'files;',skipped,'release binaries not downloaded')
for m in v['missing']:print('PENDING:',m['item'],m['action'])
if q.strict_binaries:
 assert not q.source_only,'Choose either source-only or strict-binaries'
 assert not v['missing'] and v['required_runtime_artifacts_complete'],'A required runtime artifact is missing'
 print('All required runtime artifacts are present and verified')
