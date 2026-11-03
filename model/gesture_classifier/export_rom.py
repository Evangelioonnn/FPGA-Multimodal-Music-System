"""Export the frozen classifier with B's unchanged scripts and verify all 7 files."""
from pathlib import Path
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
PACKAGE = HERE.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New directory for the seven ROM/model files')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error('Use a new output directory; existing files are never replaced')
    canonical = PACKAGE / 'fpga/gesture_vision/assets'
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='gesture_model_export_') as temp:
        job = Path(temp).resolve()
        assert job.is_relative_to(Path(tempfile.gettempdir()).resolve())
        # Match the original HERE.parents[2] layout without modifying its code.
        code = job / 'pipeline/export/standalone'
        code.mkdir(parents=True)
        for name in ('export_model.py', 'reference.py'):
            shutil.copyfile(HERE / 'source/rom_export' / name, code / name)
        weights = job / 'checkpoints/two_stage_paired_20261022_rgb32_hard'
        weights.mkdir(parents=True)
        shutil.copyfile(HERE / 'weights/quantized.npz', weights / 'quantized.npz')
        subprocess.run([sys.executable, '-B', str(code / 'export_model.py')], cwd=job,
                       env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'), check=True)
        files = sorted(p for p in canonical.iterdir() if p.is_file())
        assert len(files) == 7
        for p in files:
            if sha(code / 'assets' / p.name) != sha(p):
                raise ValueError('Export differs from the submitted model: ' + p.name)
        output.mkdir(parents=True)
        for p in files:
            shutil.copyfile(code / 'assets' / p.name, output / p.name)
    print('ROM_EXPORT_PASS: all seven files are byte-identical to the submitted FPGA model')
    print('Output:', output)


if __name__ == '__main__':
    main()
