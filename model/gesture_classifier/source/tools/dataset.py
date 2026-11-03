"""Dataset contracts and immutable fingerprint, independent of PyTorch."""
import hashlib
import json
from pathlib import Path
import numpy as np


def load_records(manifest):
    records=[json.loads(line) for line in manifest.read_text(encoding='utf-8').splitlines() if line.strip()]
    if not records:raise ValueError('empty dataset')
    groups,images={},{}
    for r in records:
        if r['split'] not in ('train','val','test'):raise ValueError('invalid split')
        if not r.get('group'):raise ValueError('record needs person/session group')
        if groups.setdefault(r['group'],r['split'])!=r['split']:raise ValueError('data leakage: group crosses splits')
        image=str((manifest.parent/r['image']).resolve())
        if images.setdefault(image,r['split'])!=r['split']:raise ValueError('data leakage: image crosses splits')
        if len(r['boxes'])>1:raise ValueError('V1 supports at most one hand per image')
        for box in r['boxes']:
            if box['class'] not in ('open','fist'):raise ValueError('invalid class')
            cx,cy,w,h=box['xywh']
            if not all(np.isfinite([cx,cy,w,h])) or not (0<=cx<1 and 0<=cy<1 and 0<w<=1 and 0<h<=1):
                raise ValueError('invalid normalized box')
            if cx-w/2< -1e-6 or cy-h/2< -1e-6 or cx+w/2>1+1e-6 or cy+h/2>1+1e-6:
                raise ValueError('box outside image')
    return records


def fingerprint(manifest,records):
    files,digests={},{}
    for r in records:
        sha=hashlib.sha256((manifest.parent/r['image']).read_bytes()).hexdigest()
        files[r['image']]=sha
        if digests.setdefault(sha,r['split'])!=r['split']:
            raise ValueError('data leakage: identical image content crosses splits')
    payload=dict(manifest_sha256=hashlib.sha256(manifest.read_bytes()).hexdigest(),images=files)
    combined=hashlib.sha256(json.dumps(payload,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return dict(sha256=combined,**payload)


def training_partitions(records, pilot=False, allow_draft=False):
    """Keep two-session experiments separate from three-split evaluations."""
    if allow_draft and not pilot:
        raise ValueError('draft labels are allowed only with explicit pilot mode')
    splits = [[r for r in records if r['split'] == name] for name in ('train','val','test')]
    train,val,test = splits
    if pilot:
        if not train or not val or test:
            raise ValueError('pilot requires train and val only; do not repurpose a test split')
    elif not train or not val or not test:
        raise ValueError('all three splits required')
    states={r.get('label_status','reviewed') for r in records}
    if not states <= {'draft','reviewed'}:
        raise ValueError('exclude rejected frames before training')
    if 'draft' in states and not allow_draft:
        raise ValueError('unreviewed labels; review them or explicitly allow drafts in pilot mode')
    classes={b['class'] for r in train for b in r['boxes']}
    if classes != {'open','fist'}:
        raise ValueError('training needs both classes')
    if not any(not r['boxes'] for r in train):
        raise ValueError('training needs empty backgrounds')
    return train,val,test
