"""Build the final 0.21 app from final Java inputs; never access hardware.
The supplied APK is the original signed C delivery. A local rebuild uses your
own signing key and therefore is not promised to have the same APK bytes.
"""
from pathlib import Path
import argparse, os, shutil, subprocess, zipfile
P=Path(__file__).resolve().parent
a=argparse.ArgumentParser();a.add_argument('--unsigned',action='store_true');args=a.parse_args()
sdk=Path(os.environ.get('ANDROID_SDK_ROOT')or os.environ.get('ANDROID_HOME')or 'SET_ANDROID_SDK_ROOT')
javac=shutil.which('javac')or shutil.which('javac.exe')
jdk=Path(os.environ['JAVA_HOME'])if os.environ.get('JAVA_HOME')else Path(javac).resolve().parents[1]if javac else Path('SET_JAVA_HOME')
versions=list((sdk/'build-tools').glob('*'))
bt=Path(os.environ['ANDROID_BUILD_TOOLS'])if os.environ.get('ANDROID_BUILD_TOOLS')else max(versions,key=lambda x:tuple(int(z)if z.isdigit()else 0 for z in x.name.replace('-','.').split('.')))if versions else Path('SET_ANDROID_BUILD_TOOLS')
jar=Path(os.environ.get('ANDROID_JAR',str(sdk/'platforms/android-35/android.jar')))
assert jar.is_file(),'Set ANDROID_SDK_ROOT with platform android-35 installed, or ANDROID_JAR'
def tool(folder,n):
 p=folder/(n+'.exe');return p if p.exists()else folder/n
assert tool(jdk/'bin','javac').is_file(),'Set JAVA_HOME to JDK17+'
work=P/'build';work.mkdir(exist_ok=True);classes=work/'classes';classes.mkdir(exist_ok=True);dex=work/'dex';dex.mkdir(exist_ok=True)
env=dict(os.environ,JAVA_HOME=str(jdk),PATH=str(jdk/'bin')+os.pathsep+os.environ['PATH'])
def run(cmd):
 r=subprocess.run(list(map(str,cmd)),cwd=work,env=env,capture_output=True,text=True,errors='replace',timeout=240)
 if r.returncode:raise RuntimeError(r.stdout+r.stderr)
 return r.stdout+r.stderr
sources=sorted((P/'src').glob('*.java'))
run([tool(jdk/'bin','javac'),'-encoding','UTF-8','--release','8','-classpath',jar,'-d',classes,*sources])
run([tool(jdk/'bin','java'),'-cp',bt/'lib/d8.jar','com.android.tools.r8.D8','--lib',jar,'--min-api','26','--output',dex,*sorted(classes.rglob('*.class'))])
resources=work/'resources.zip';unsigned=work/'unsigned.apk';aligned=work/'aligned.apk'
run([tool(bt,'aapt2'),'compile','--dir',P/'res','-o',resources])
run([tool(bt,'aapt2'),'link','-I',jar,'--manifest',P/'AndroidManifest.xml','--min-sdk-version','26','--target-sdk-version','35','-o',unsigned,resources])
with zipfile.ZipFile(unsigned,'a',compression=zipfile.ZIP_DEFLATED)as z:
 z.write(dex/'classes.dex','classes.dex')
 for f in sorted((P/'assets').rglob('*')):
  if f.is_file():z.write(f,'assets/'+f.relative_to(P/'assets').as_posix())
run([tool(bt,'zipalign'),'-f','4',unsigned,aligned])
if args.unsigned:print('Unsigned aligned APK:',aligned)
else:
 key=Path(os.environ.get('ANDROID_KEYSTORE','SET_ANDROID_KEYSTORE'));assert key.is_file(),'Set ANDROID_KEYSTORE to your own key, or use --unsigned'
 # The SDK signer requests signing passwords interactively; no key or secret is distributed.
 out=work/'qinjian-rebuilt.apk'
 cmd=[str(tool(jdk/'bin','java')),'-jar',str(bt/'lib/apksigner.jar'),'sign','--ks',str(key),'--out',str(out),str(aligned)]
 subprocess.run(cmd,cwd=work,env=env,check=True)
 print('Signed local rebuild:',out)
