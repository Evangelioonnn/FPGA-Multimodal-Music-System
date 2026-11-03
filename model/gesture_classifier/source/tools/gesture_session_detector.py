"""Matched reviewed-session SSD continuation in the runtime letterbox geometry.

Only hand/head localization is learned. Non-target gestures/objects without
hand boxes are ignored by localization training, never labelled hand-free.
"""
import argparse,copy,json,math,shutil,time
from pathlib import Path
import numpy as np
from PIL import Image
import torch
from torch import nn
from gesture_detector_adaptation import (LAB,sha,read,development,detector_truth,reference_parts,best_detection,match,multibox_loss)
from gesture_context_adaptation import detector_view,recover_box
from gesture_spatial_quality import valid_box
from gesture_feature_adaptation import restore_state
from pretrained_reference import Reference,center_rgb,normalized_iou
from provenance import source_fingerprint

PROTOCOL=dict(seed=20261017,epochs=30,batch_size=16,lr=.0001,weight_decay=.0001,private_repeat=3,eval_every=5,
 input='letterbox320x240,central240square at x40',detector_score=.3,match_iou=.35,neg_pos_ratio=3,
 selection='old239 no-hand false counts may not increase;min/mean domain localization;epoch0 fallback',
 ex_used_for_selection=False,arms=['old437','add_s05'],test_evaluated=False,fpga_deployed=False)

def to_letterbox(box):
    if box is None:return None
    if not np.isfinite(box).all() or min(box[2:])<=0:raise ValueError('invalid box')
    x,y,w,h=map(float,box);return [.75*x+.125,y,.75*w,h]

def train_indices(rows,arm):
    if arm not in PROTOCOL['arms']:raise ValueError('unknown arm')
    if any(r.get('label_status')!='reviewed' or r['split'] not in ('train','val') or str(r.get('source_video','')).startswith('s06') for r in rows):raise ValueError('reviewed development only')
    return [i for i,r in enumerate(rows) if r['split']=='train' and r['detector_label_status']!='ignore' and (arm=='add_s05' or not r['new_session'])]

def location_metrics(rows,boxes,ids):
    groups={}
    for i in ids:
        r,b=rows[i],boxes[i];name=r['group'] if r['origin']=='private' else 'public_val';g=groups.setdefault(name,dict(targets=0,localized=0,no_hand=0,false_hand=0))
        if r['detector_box'] is not None:
            g['targets']+=1;g['localized']+=int(b is not None and normalized_iou(b,r['detector_box'])>=.5)
        if r['detector_label_status']=='background':g['no_hand']+=1;g['false_hand']+=int(b is not None)
    return groups

def location_rank(groups,baseline):
    safe=all(g['false_hand']<=baseline[k]['false_hand'] for k,g in groups.items())
    values=[g['localized']/g['targets'] for g in groups.values() if g['targets']]
    return int(safe),min(values),float(np.mean(values)),-sum(g['false_hand'] for g in groups.values())

@torch.no_grad()
def predictions(heads,features,priors):
    boxes=[];scores=[]
    for start in range(0,len(features[0]),16):
        c,l=heads([f[start:start+16] for f in features])
        for a,b in zip(c,l):
            p=best_detection(a,b,priors,.3);box=recover_box(p['box'],(.75,.125,False));boxes.append(box if valid_box(box) else None);scores.append(p['score'])
    return boxes,scores

def cache(adoption,out):
    if out.exists() or out.with_suffix('.json').exists():raise ValueError('new cache required')
    torch.set_num_threads(2);sources=source_fingerprint(LAB);a=read(adoption);records,identities=development(Path(a['public_manifest']),Path(a['private_manifest']))
    if len(records)!=767:raise ValueError('unexpected reviewed schedule')
    models=LAB/'model_export/reference_dynamic_557a_20261016';_,session,priors,_=reference_parts(models);reference=Reference(models)
    maps=[[] for _ in range(4)];rows=[]
    for i,r in enumerate(records):
        with Image.open(r['path']) as im:rgb=center_rgb(im);truth,status=detector_truth(r,im.size)
        # Inference geometry matches the retained automatic runtime exactly.
        image,_=detector_view(rgb,'letterbox',reference);values=session.run(None,{'input':reference.tensor(image,(320,240))})[:4]
        for k,v in enumerate(values):maps[k].append(v[0])
        rows.append(dict(r,detector_box=truth,detector_label_status=status,new_session=r.get('source_video','').startswith(('s05 ','ex '))))
        if (i+1)%150==0:print(json.dumps(dict(detector_cached=i+1)),flush=True)
    for arm in PROTOCOL['arms']:train_indices(rows,arm)
    out.parent.mkdir(parents=True,exist_ok=True);np.savez_compressed(out,**{f'features{k}':np.stack(v) for k,v in enumerate(maps)},priors=priors)
    result=dict(rows=rows,models=str(models.resolve()),dataset_identities=identities,source_sha256=sources,cache_sha256=sha(out),adoption_path=str(adoption.resolve()),adoption_sha256=sha(adoption),protocol=PROTOCOL)
    assert sources==source_fingerprint(LAB);out.with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(status='PASS',detector_cached=len(rows))),flush=True)

def validate(path):
    from dataset import load_records,fingerprint
    info=read(path.with_suffix('.json'));current=source_fingerprint(LAB)
    if sha(path)!=info['cache_sha256'] or any(current.get(k)!=v for k,v in info['source_sha256'].items()):raise ValueError('cache/source changed')
    for s in info['dataset_identities']:
        p=Path(s['path'])
        if fingerprint(p,load_records(p))!=s['identity']:raise ValueError('reviewed data changed')
    return info

def train(cache_path,out,arm):
    if out.exists():raise ValueError('new experiment required')
    torch.set_num_threads(2);torch.manual_seed(PROTOCOL['seed']);info=validate(cache_path);sources=source_fingerprint(LAB);rows=info['rows'];ids=train_indices(rows,arm)
    oldval=[i for i,r in enumerate(rows) if r['split']=='val' and not r['new_session']];ex=[i for i,r in enumerate(rows) if r['split']=='val' and r['new_session']]
    newtrain=[i for i,r in enumerate(rows) if r['split']=='train' and r['new_session']]
    assert len(oldval)==239 and len(ex)==20
    with np.load(cache_path,allow_pickle=False) as a:features=[torch.from_numpy(a[f'features{k}'].copy()) for k in range(4)];priors=torch.from_numpy(a['priors'].copy())
    heads,_,_,_=reference_parts(Path(info['models']));parent=LAB/'checkpoints/detector_head_adaptation_20261016/heads.npz';restore_state(heads,parent);heads.eval()
    boxes,scores=predictions(heads,features,priors);baseline=location_metrics(rows,boxes,oldval)
    labels=[];truth=[]
    for r in rows:
        a,b=match(priors,to_letterbox(r['detector_box']));labels.append(a);truth.append(b)
    labels,truth=torch.stack(labels),torch.stack(truth)
    schedule=np.array([i for i in ids for _ in range(3 if rows[i]['origin']=='private' else 1)])
    optimizer=torch.optim.AdamW(heads.parameters(),lr=.0001,weight_decay=.0001);rng=np.random.default_rng(PROTOCOL['seed'])
    out.mkdir(parents=True)
    for rel in sources:p=out/'source'/rel;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(LAB/rel,p)
    (out/'FROZEN_PROTOCOL.json').write_text(json.dumps(dict(protocol=PROTOCOL,arm=arm,source_sha256=sources,cache_sha256=sha(cache_path),initialization_sha256=sha(parent)),indent=2)+'\n',encoding='utf-8')
    best=copy.deepcopy(heads.state_dict());best_rank=location_rank(baseline,baseline);best_epoch=0;history=[];start=time.monotonic()
    for epoch in range(30):
        heads.train();losses=[]
        for own in np.array_split(rng.permutation(schedule),math.ceil(len(schedule)/16)):
            optimizer.zero_grad();c,l=heads([f[own] for f in features]);loss=multibox_loss(c,l,labels[own],truth[own]);loss.backward();nn.utils.clip_grad_norm_(heads.parameters(),5);optimizer.step();losses.append(float(loss.detach()))
        if (epoch+1)%5==0:
            heads.eval();boxes,scores=predictions(heads,features,priors);groups=location_metrics(rows,boxes,oldval);rank=location_rank(groups,baseline)
            if rank>best_rank:best_rank=rank;best=copy.deepcopy(heads.state_dict());best_epoch=epoch+1
            history.append(dict(epoch=epoch+1,loss=float(np.mean(losses)),rank=list(rank),groups=groups));print(json.dumps(dict(arm=arm,epoch=epoch+1,best_epoch=best_epoch,rank=list(best_rank))),flush=True)
    heads.load_state_dict(best);heads.eval();boxes,scores=predictions(heads,features,priors);np.savez(out/'heads.npz',**{k:v.detach().numpy() for k,v in heads.state_dict().items()})
    result=dict(status='OFFLINE_SESSION_LOCALIZATION_CONTINUATION',arm=arm,protocol=PROTOCOL,source_sha256=sources,cache_path=str(cache_path.resolve()),cache_sha256=sha(cache_path),head_sha256=sha(out/'heads.npz'),initialization_sha256=sha(parent),
        selected_epoch=best_epoch,rank=list(best_rank),baseline_old239=baseline,old239=location_metrics(rows,boxes,oldval),ex20=location_metrics(rows,boxes,ex),s05_training_diagnostic=location_metrics(rows,boxes,newtrain),
        training_images=len(ids),training_draws_per_epoch=len(schedule),ignored_train_images=sum(r['split']=='train' and r['detector_label_status']=='ignore' and (arm=='add_s05' or not r['new_session']) for r in rows),
        predictions=[dict(r,predicted_box=b,detector_score=s) for r,b,s in zip(rows,boxes,scores)],history=history,elapsed_seconds=time.monotonic()-start,
        ex_used_for_selection=False,test_evaluated=False,fpga_deployed=False,board_tested=False,model_promoted=False)
    assert sources==source_fingerprint(LAB);(out/'REPORT.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(json.dumps(dict(arm=arm,epoch=best_epoch,old=result['old239'],ex=result['ex20'],s05=result['s05_training_diagnostic'])),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();s=p.add_subparsers(dest='command',required=True)
    c=s.add_parser('cache');c.add_argument('--adoption',type=Path,required=True);c.add_argument('--out',type=Path,required=True)
    t=s.add_parser('train');t.add_argument('--cache',type=Path,required=True);t.add_argument('--out',type=Path,required=True);t.add_argument('--arm',choices=PROTOCOL['arms'],required=True)
    a=p.parse_args()
    if a.command=='cache':cache(a.adoption,a.out)
    else:train(a.cache,a.out,a.arm)
