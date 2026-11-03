"""Complete GNU Arm MCU builds; no size-limited linker and no hardware calls."""
from pathlib import Path
import subprocess,json,hashlib,os
P=Path(__file__).resolve().parents[1]
import shutil
located=shutil.which('arm-none-eabi-gcc') or shutil.which('arm-none-eabi-gcc.exe')
DEFAULT=Path(located).parent if located else Path('SET_ARM_GNU_BIN')
BIN=Path(os.environ.get('ARM_GNU_BIN',str(DEFAULT)))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    sources=[*sorted((P/'src').glob('*.c')),P/'vendor/littlefs/lfs.c',P/'vendor/littlefs/lfs_util.c',P/'board/weact_f411/main.c',P/'board/weact_f411/startup_gnu.c']
    bound=[*sources,*sorted((P/'include').glob('*.h')),P/'vendor/littlefs/lfs.h',P/'vendor/littlefs/lfs_util.h',P/'board/weact_f411/f411.ld',Path(__file__)]
    reports=[]
    for profile,writes in [('library',1)]:
        work=P.parents[1]/'bin/library_gateway';work.mkdir(parents=True,exist_ok=True);logs=[];objects=[]
        def run(args):
            r=subprocess.run(list(map(str,args)),cwd=work,capture_output=True,text=True,errors='replace',timeout=120);logs.append(r.stdout+r.stderr);(work/'build.log').write_text('\n'.join(logs),encoding='utf-8')
            if r.returncode:raise RuntimeError((r.stdout+r.stderr)[-6000:])
            return r.stdout+r.stderr
        base=['-mcpu=cortex-m4','-mthumb','-mfloat-abi=soft','-Os','-g3','-ffunction-sections','-fdata-sections','-fno-common','-fstack-usage','-std=c99','-Wall','-Wextra','-Wno-misleading-indentation',
              '-ffile-prefix-map='+str(P)+'=.','-fdebug-prefix-map='+str(P)+'=.',
              '-DLFS_NO_MALLOC','-DLFS_NO_DEBUG','-DLFS_NO_WARN','-DLFS_NO_ERROR','-DLIBRARY_WRITES='+str(writes),'-I'+str(P/'include'),'-I'+str(P/'vendor/littlefs')]
        for source in sources:
            obj=work/(source.stem+'.o');objects.append(obj);run([BIN/'arm-none-eabi-gcc.exe',*base,'-c',source,'-o',obj])
        elf=work/'library_gateway.elf';hexfile=work/'library_gateway.hex'
        run([BIN/'arm-none-eabi-gcc.exe','-mcpu=cortex-m4','-mthumb','-mfloat-abi=soft','-nostartfiles','--specs=nano.specs','--specs=nosys.specs','-T',P/'board/weact_f411/f411.ld','-Wl,--gc-sections','-Wl,-Map='+str(work/'library_gateway.map'),*objects,'-o',elf])
        run([BIN/'arm-none-eabi-objcopy.exe','-O','ihex',elf,hexfile]);sizes=run([BIN/'arm-none-eabi-size.exe',elf]);version=run([BIN/'arm-none-eabi-gcc.exe','--version'])
        stack='\n'.join(p.read_text() for p in sorted(work.glob('*.su')))
        (work/'stack_usage.txt').write_text(stack,encoding='utf-8')
        reports.append(dict(profile=profile,build_pass=True,hardware='NOT_RUN',clock='HSI16MHz',uart='115200/8N1',stack_reserved_bytes=24576,
            writes_enabled=bool(writes),compiler=version,sizes=sizes,hex=str(hexfile.relative_to(P.parents[1])).replace('\\','/'),hex_sha256=sha(hexfile),
            source_sha256={str(p.relative_to(P)).replace('\\','/'):sha(p) for p in bound}))
        print('GNU_MCU_BUILD_PASS',profile,sizes.strip())
    (P.parents[1]/'bin/library_gateway/build_info.json').write_text(json.dumps(reports,indent=2)+'\n')
if __name__=='__main__':main()
