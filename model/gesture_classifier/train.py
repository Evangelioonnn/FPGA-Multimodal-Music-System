"""Prepare or run the final RGB32 cached-data training in a fresh external folder."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
PACKAGE = HERE.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True, help='New directory outside the submission')
    parser.add_argument('--prepare-only', action='store_true', help='Prepare inputs without starting training')
    args = parser.parse_args()
    job = args.work_dir.resolve()
    if job.exists() or job.is_relative_to(PACKAGE):
        parser.error('Use a new work directory outside the submission')
    job.mkdir(parents=True)
    shutil.copytree(HERE / 'source/training', job / 'two_stage_transfer')
    shutil.copytree(HERE / 'source/tools', job / 'tools')
    shutil.copytree(HERE / 'training_cache', job / 'work/two_stage_transfer_20261022')
    print('Training workspace:', job, flush=True)
    if args.prepare_only:
        print('Inputs prepared; training was not started')
        return
    subprocess.run([sys.executable, '-B', str(job / 'two_stage_transfer/paired_student.py'),
                    '--arm', 'rgb32_hard'], cwd=job,
                   env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'), check=True)


if __name__ == '__main__':
    main()
