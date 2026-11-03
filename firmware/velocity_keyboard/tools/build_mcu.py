"""Build files only; never connect to or program an STM32."""
from pathlib import Path
import argparse,subprocess,hashlib,json,os,shutil
P=Path(__file__).resolve().parents[1];R=P.parents[1]
a=argparse.ArgumentParser();a.add_argument('--gcc',type=Path);args=a.parse_args()
candidate=shutil.which('arm-none-eabi-gcc') or shutil.which('arm-none-eabi-gcc.exe')
found=[Path(candidate)] if candidate else []
gcc=args.gcc or (found[0] if found else None)
if not gcc:raise SystemExit('Install Arm GNU toolchain and pass --gcc /path/arm-none-eabi-gcc')
gcc=gcc.resolve();B=R/'bin/velocity_keyboard';B.mkdir(parents=True,exist_ok=True)
env=dict(os.environ);env['PATH']=str(gcc.parent)+os.pathsep+env['PATH']
sources=[P/'mcu/main.c',P/'mcu/capture.c',P/'mcu/capture.h',P/'mcu/startup.S',P/'mcu/stm32f103c8.ld']
flags=['-mcpu=cortex-m3','-mthumb','-Os','-g3','-ffreestanding','-fno-builtin','-ffunction-sections','-fdata-sections','-Wall','-Wextra','-Werror','-std=c11']
elf=B/'velocity_keyboard.elf'
cmd=[gcc,*flags,'-I',P/'mcu',P/'mcu/startup.S',P/'mcu/main.c',P/'mcu/capture.c','-nostdlib',
 '-T',P/'mcu/stm32f103c8.ld','-Wl,--gc-sections','-Wl,-Map='+str(B/'velocity_keyboard.map'),'-lgcc','-o',elf]
q=subprocess.run(list(map(str,cmd)),capture_output=True,text=True,env=env)
(B/'compile.log').write_text(q.stdout+q.stderr,encoding='utf-8')
if q.returncode:raise RuntimeError(q.stderr)
# Publish ELF without host-specific debug metadata; program bytes remain unchanged.
subprocess.run([str(gcc.parent/'arm-none-eabi-objcopy.exe'),'--strip-debug',str(elf)],check=True,env=env)
for fmt,ext in [('ihex','hex'),('binary','bin')]:
 subprocess.run([str(gcc.parent/'arm-none-eabi-objcopy.exe'),'-O',fmt,str(elf),str(B/('velocity_keyboard.'+ext))],check=True,env=env)
size=subprocess.check_output([str(gcc.parent/'arm-none-eabi-size.exe'),str(elf)],text=True,env=env)
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
d=dict(pass_=True,tool=subprocess.check_output([str(gcc),'--version'],text=True,env=env).splitlines()[0],
 sources={f.relative_to(R).as_posix():sha(f) for f in sources+[Path(__file__).resolve()]},
 outputs={f.name:sha(f) for f in [elf,B/'velocity_keyboard.hex',B/'velocity_keyboard.bin']},
 size=size,flash_limit=65536,ram_limit=20480,stack_reserve=2048,programmed=False,board=False)
(B/'build_info.json').write_text(json.dumps(d,indent=2)+'\n')
print('MCU_BUILD_PASS',size,flush=True)
