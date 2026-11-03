"""RGB32 ROI classifier EXPERIMENT, not a drop-in MY64 detector.

Input crops are supplied by annotations in this diagnostic. A deployable crop
finder (fixed operating region / color tracker / hand detector) remains needed.
Architecture idea: official dynamic_gestures local-conv/residual/pooling/linear
classifier, independently reduced to 8 channels and three project classes.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import random
import time

import numpy as np
from PIL import Image
import torch
from torch import nn
from torch.nn import functional as F

from dataset import load_records,fingerprint,training_partitions
from pretrained_reference import Reference,center_rgb,roi_box
from provenance import source_fingerprint

LAB=Path(__file__).resolve().parents[1]
FORMAT='ROI32_RGB_C8_CLASSIFIER_EXPERIMENT_V1'


def record_box(row,size):
    if row['boxes']:return roi_box(row['boxes'][0]['xywh'],size)
    # Public negatives may carry a reviewed hand ROI. Self-capture negatives
    # can deliberately label only the full frame; do not invent a hand box.
    if row.get('negative_kind')=='non_target_gesture' and row.get('source_all_bboxes_topleft_xywh'):
        x,y,w,h=row['source_all_bboxes_topleft_xywh'][0]
        return roi_box([x+w/2,y+h/2,w,h],size)
    return None


def crop_rgb(rgb,box,context=1.25):
    side=rgb.shape[0]
    x,y,w,h=box if box is not None else [.5,.5,.4,.4]
    length=max(4,int(math.ceil(max(w,h)*side*context)))
    left=int(math.floor(x*side-length/2));top=int(math.floor(y*side-length/2))
    pad=max(0,-left,-top,left+length-side,top+length-side)
    padded=np.pad(rgb,((pad,pad),(pad,pad),(0,0)),mode='edge') if pad else rgb
    return padded[top+pad:top+pad+length,left+pad:left+pad+length].copy()


def sample32(rgb):
    h,w=rgb.shape[:2];ys=np.arange(32)*h//32;xs=np.arange(32)*w//32
    return rgb[ys[:,None],xs[None,:]].transpose(2,0,1).copy()


def teacher_targets(logits,labels,temperature=2):
    values=np.asarray(logits,dtype=np.float64)/temperature
    values=np.exp(values-values.max());values/=values.sum()
    opened=sum(values[i] for i,label in enumerate(labels) if label in ('palm','stop','stop_inverted'))
    fist=sum(values[i] for i,label in enumerate(labels) if label in ('fist','fist_inverted'))
    result=np.array([max(0,1-opened-fist),opened,fist],np.float32)
    return result/result.sum()


def prepare_cache(manifest,models,out,split=None):
    if out.exists():raise ValueError('use a new cache filename')
    rows=load_records(manifest)
    if split:rows=[r for r in rows if r['split']==split]
    if any(r['split']=='test' for r in rows):raise ValueError('ROI development cache excludes test')
    before=fingerprint(manifest,rows);teacher=Reference(models)
    images=[];labels=[];soft=[];meta=[]
    for row in rows:
        with Image.open(manifest.parent/row['image']) as im:rgb=center_rgb(im);size=im.size
        box=record_box(row,size);crop=crop_rgb(rgb,box)
        label={'open':1,'fist':2}.get(row['boxes'][0]['class'],0) if row['boxes'] else 0
        images.append(sample32(crop));labels.append(label)
        soft.append(teacher_targets(teacher.classify(crop)['logits'],teacher.labels) if box is not None else np.array([1,0,0],np.float32))
        meta.append(dict(image=row['image'],group=row['group'],split=row['split'],label_status=row['label_status'],
            expected=label,negative_kind=row.get('negative_kind'),annotation_roi_supplied=box is not None))
    if before!=fingerprint(manifest,rows):raise ValueError('data changed during cache')
    out.parent.mkdir(parents=True,exist_ok=True)
    np.savez_compressed(out,images=np.stack(images),labels=np.array(labels,np.int64),soft_targets=np.stack(soft))
    info=dict(format=FORMAT,dataset=before,source_manifest=str(manifest),images=len(rows),rows=meta,
        cache_sha256=hashlib.sha256(out.read_bytes()).hexdigest(),oracle_roi=True,independent_end_to_end=False,
        teacher_commit='557a836bf82fce8d36494d0c17e95ca236f5611c',teacher_temperature=2,
        teacher_hagrid_overlap_possible=any('hagrid' in r.get('source','').lower() for r in rows))
    out.with_suffix('.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(cache=str(out),images=len(rows),oracle_roi=True),indent=2),flush=True)


class ROIClassifier(nn.Module):
    def __init__(self,norms=True):
        super().__init__()
        self.conv1=nn.Conv2d(3,8,3,padding=1);self.conv2=nn.Conv2d(8,8,3,padding=1)
        self.skip=nn.Conv2d(3,8,1);self.linear=nn.Linear(512,3)
        self.norm1=nn.BatchNorm2d(8,momentum=.05) if norms else nn.Identity()
        self.norm2=nn.BatchNorm2d(8,momentum=.05) if norms else nn.Identity()
        for layer in (self.conv1,self.conv2,self.skip,self.linear):
            nn.init.kaiming_normal_(layer.weight,nonlinearity='linear' if layer is self.linear else 'relu');nn.init.zeros_(layer.bias)
        nn.init.zeros_(self.skip.weight)
        if norms:
            nn.init.constant_(self.norm1.weight,.25);nn.init.constant_(self.norm2.weight,.25)

    def forward(self,x):
        y=self.norm1(self.conv1(x)).clamp(0,127/128)
        y=(self.norm2(self.conv2(y))+self.skip(x)).clamp(0,127/128)
        return self.linear(F.avg_pool2d(y,4).flatten(1))

    def folded(self):
        self.eval();result=ROIClassifier(False).eval()
        result.conv1=torch.nn.utils.fusion.fuse_conv_bn_eval(self.conv1,self.norm1)
        result.conv2=torch.nn.utils.fusion.fuse_conv_bn_eval(self.conv2,self.norm2)
        result.skip=copy.deepcopy(self.skip);result.linear=copy.deepcopy(self.linear)
        return result


def quantize(model):
    result={}
    for name in ('conv1','conv2','skip','linear'):
        layer=getattr(model,name);w=layer.weight.detach().numpy();b=layer.bias.detach().numpy()
        shift=min(12,max(0,int(np.floor(np.log2(127/max(float(abs(w).max()),1e-8))))))
        qw=np.clip(np.round(w*2**shift),-128,127).astype(np.int8)
        qb=np.round(b*128*2**shift).astype(np.int64)
        bound=127*np.abs(qw.astype(np.int64)).reshape(len(qw),-1).sum(axis=1)+np.abs(qb)
        if max(bound)>2147483647:raise ValueError('integer accumulator overflow')
        result[name+'_w']=qw;result[name+'_b']=qb.astype(np.int32);result[name+'_shift']=np.int64(shift)
    return result


def int_conv(x,w,b):
    k=w.shape[-1];pad=k//2
    padded=np.pad(x,((0,0),(pad,pad),(pad,pad)))
    view=np.lib.stride_tricks.sliding_window_view(padded,(k,k),axis=(1,2))
    return np.einsum('iyxab,oiab->oyx',view.astype(np.int64),w.astype(np.int64),optimize=True)+b[:,None,None]


def integer_logits(image,q):
    x=(image>>1).astype(np.int64)
    y=np.clip(int_conv(x,q['conv1_w'],q['conv1_b'])>>int(q['conv1_shift']),0,127)
    main=int_conv(y,q['conv2_w'],q['conv2_b'])>>int(q['conv2_shift'])
    skip=int_conv(x,q['skip_w'],q['skip_b'])>>int(q['skip_shift'])
    z=np.clip(main+skip,0,127)
    pool=(z.reshape(8,8,4,8,4).sum(axis=(2,4))>>4).reshape(512)
    return np.clip((q['linear_w'].astype(np.int64)@pool+q['linear_b'])>>(int(q['linear_shift'])+3),-128,127).astype(np.int8)


def decode(logits,margin=8):
    values=np.asarray(logits,dtype=np.int32);best=values.argmax(axis=-1)
    sorted_values=np.sort(values,axis=-1)
    return np.where((best!=0)&(sorted_values[...,-1]-sorted_values[...,-2]<margin),0,best)


def metrics(logits,labels):
    predicted=decode(logits);matrix=np.zeros((3,3),np.int64)
    for a,b in zip(labels,predicted):matrix[int(a),int(b)]+=1
    return dict(images=len(labels),confusion_other_open_fist=matrix.tolist(),
        class_correct=int(np.trace(matrix)),target_correct=int(matrix[1,1]+matrix[2,2]),target_images=int(matrix[1:].sum()),
        false_target=int(matrix[0,1:].sum()),negative_images=int(matrix[0].sum()),
        balanced_accuracy=float(np.mean(np.diag(matrix)/np.maximum(matrix.sum(axis=1),1))))


def float_logits(model,images):
    outputs=[];model.eval()
    with torch.no_grad():
        for begin in range(0,len(images),64):
            x=torch.from_numpy((images[begin:begin+64]>>1).astype(np.float32)/128)
            outputs.append(np.clip(np.floor(model(x).numpy()*16),-128,127).astype(np.int8))
    return np.concatenate(outputs)


def train(cache,out,distill=False,epochs=300,seed=20261016):
    if out.exists():raise ValueError('use a new checkpoint directory')
    if epochs<1:raise ValueError('positive epochs required')
    info=json.loads(cache.with_suffix('.json').read_text(encoding='utf-8'))
    if hashlib.sha256(cache.read_bytes()).hexdigest()!=info['cache_sha256']:raise ValueError('cache changed')
    with np.load(cache,allow_pickle=False) as f:images=f['images'];labels=f['labels'];soft=f['soft_targets']
    rows=info['rows'];source_manifest=Path(info['source_manifest']);raw_rows=load_records(source_manifest)
    training_partitions(raw_rows,pilot=True,allow_draft=True)
    if fingerprint(source_manifest,raw_rows)!=info['dataset']:raise ValueError('source no longer matches cache')
    train_indices=np.array([i for i,r in enumerate(rows) if r['split']=='train']);val=np.array([i for i,r in enumerate(rows) if r['split']=='val'])
    random.seed(seed);np.random.seed(seed);torch.manual_seed(seed);torch.set_num_threads(2)
    model=ROIClassifier();optimizer=torch.optim.AdamW(model.parameters(),lr=.001,weight_decay=.0005)
    sources=source_fingerprint(LAB);out.mkdir(parents=True);start=time.monotonic();rng=np.random.default_rng(seed)
    best,best_rank,best_epoch=None,None,None;history=[]
    for epoch in range(epochs):
        rate=min(1,(epoch+1)/5)*(.05+.95*(1+math.cos(math.pi*epoch/max(1,epochs-1)))/2)
        for g in optimizer.param_groups:g['lr']=.001*rate
        model.train();order=rng.permutation(train_indices);losses=[]
        for begin in range(0,len(order),32):
            indices=order[begin:begin+32];batch=[]
            for i in indices:
                im=images[i].transpose(1,2,0)
                if rng.random()<.5:im=im[:,::-1]
                im=np.clip(im.astype(np.float32)*rng.uniform(.85,1.15)+rng.uniform(-8,8),0,255).astype(np.uint8)
                batch.append(im.transpose(2,0,1).copy())
            x=torch.from_numpy((np.stack(batch)>>1).astype(np.float32)/128);target=torch.from_numpy(labels[indices])
            optimizer.zero_grad();logits=model(x);hard=F.cross_entropy(logits,target);loss=hard
            if distill:loss=.7*hard+.3*4*F.kl_div(F.log_softmax(logits/2,dim=1),torch.from_numpy(soft[indices]),reduction='batchmean')
            loss.backward();nn.utils.clip_grad_norm_(model.parameters(),10);optimizer.step();losses.append(float(loss.detach()))
        if epoch==0 or (epoch+1)%10==0 or epoch+1==epochs:
            score=metrics(float_logits(model,images[val]),labels[val]);rank=(score['balanced_accuracy'],score['target_correct'],-score['false_target'])
            entry=dict(epoch=epoch+1,loss=float(np.mean(losses)),validation=score);history.append(entry);print(json.dumps(entry),flush=True)
            if best_rank is None or rank>best_rank:best_rank=rank;best_epoch=epoch+1;best=copy.deepcopy(model.state_dict())
    model.load_state_dict(best);model.eval();folded=model.folded()
    with torch.no_grad():
        x=torch.from_numpy((images[val]>>1).astype(np.float32)/128)
        torch.testing.assert_close(model(x),folded(x),rtol=3e-5,atol=3e-5)
        fold_error=float((model(x)-folded(x)).abs().max())
    q=quantize(folded);evaluations={}
    for split,indices in [('train',train_indices),('val',val)]:
        evaluations[split+'_float']=metrics(float_logits(folded,images[indices]),labels[indices])
        evaluations[split+'_int8']=metrics(np.stack([integer_logits(im,q) for im in images[indices]]),labels[indices])
    if sources!=source_fingerprint(LAB):raise ValueError('source changed during training')
    torch.save(folded.state_dict(),out/'weights.pt');np.savez(out/'roi_classifier_int8.npz',**q)
    report=dict(status='ORACLE_ROI_CLASSIFICATION_EXPERIMENT_ONLY',format=FORMAT,distillation=distill,epochs=epochs,best_epoch=best_epoch,
        seed=seed,parameters=sum(p.numel() for p in folded.parameters()),elapsed_seconds=time.monotonic()-start,
        training_images=len(train_indices),validation_images=len(val),draft_training_images=sum(rows[i]['label_status']=='draft' for i in train_indices),
        dataset_cache_sha256=info['cache_sha256'],source_sha256=sources,history=history,fold_maximum_error=fold_error,
        input_rgb32=True,oracle_roi=True,requires_runtime_roi_finder=True,fpga_rtl_implemented=False,test_evaluated=False,
        approved_for_gesture_use=False,**evaluations)
    (out/'TRAINING_REPORT.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ('source_sha256','history')},indent=2),flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser();sub=p.add_subparsers(dest='command',required=True)
    c=sub.add_parser('cache');c.add_argument('--manifest',type=Path,required=True);c.add_argument('--models',type=Path,required=True);c.add_argument('--out',type=Path,required=True);c.add_argument('--split',choices=['train','val'])
    t=sub.add_parser('train');t.add_argument('--cache',type=Path,required=True);t.add_argument('--out',type=Path,required=True);t.add_argument('--distill',action='store_true');t.add_argument('--epochs',type=int,default=300)
    a=p.parse_args()
    if a.command=='cache':prepare_cache(a.manifest,a.models,a.out,a.split)
    else:train(a.cache,a.out,a.distill,a.epochs)
