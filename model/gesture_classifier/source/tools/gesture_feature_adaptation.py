"""Offline feature fine-tuning with automatic detector crops and reject examples.

Training boxes may supply additional crop views. Runtime/validation crops never
use boxes or expected gesture classes. This is a teacher experiment, not RTL.
"""
import argparse,copy,json,math,time
from pathlib import Path
import numpy as np
from PIL import Image
import torch
from torch import nn
from torch.nn import functional as F
from gesture_detector_adaptation import (LAB,SSDHeads,reference_parts,best_detection,
 validate,sha,read)
from pretrained_reference import center_rgb,normalized_iou
from pretrained_transfer import load_reference,project_groups,canonical_crop,measurements
from provenance import source_fingerprint
from roi_classifier import record_box

PROTOCOL=dict(seed=20261016,epochs=24,warmup_epochs=4,batch_size=12,
 head_lr=.001,backbone_lr=.00003,weight_decay=.0001,private_repeat=3,
 reject_margin=.5,eval_every=4,selection='safety eligibility then minimum full-pipeline domain recall',
 private_false_target_limit=0,public_false_target_fraction_limit=.05,
 augmentation='horizontal flip and bounded brightness/contrast; validation unchanged')

def restore_state(model,path):
 with np.load(path,allow_pickle=False) as a:
  state={k:torch.from_numpy(a[k].copy()) for k in a.files}
 model.load_state_dict(state,strict=True)

class TunableClassifier(nn.Module):
 def __init__(self,backbone,groups):
  super().__init__();self.backbone=backbone;self.groups=groups;self.head=nn.Linear(2048,3)
  nn.init.zeros_(self.head.weight);nn.init.zeros_(self.head.bias)
  self.backbone.classifier.requires_grad_(False)

 def feature_parameters(self):
  return [p for name,p in self.backbone.named_parameters() if not name.startswith('classifier.')]

 def parts(self,x):
  f=self.backbone.features(x);teacher=self.backbone.classifier(f)
  base=torch.stack([teacher[:,group].max(1).values for group in self.groups],1)
  delta=self.head(F.layer_norm(f,(2048,)))
  return base+delta,teacher,delta

 def forward(self,x):return self.parts(x)[0]

def preserve_negative_loss(student45,teacher45,delta):
 # T=2 KL preserves the original 45-way non-target taxonomy. The additional
 # correction penalty discourages overriding a confident non-target decision.
 if not len(student45):return student45.sum()*0+delta.sum()*0
 distillation=F.kl_div(F.log_softmax(student45/2,dim=1),F.softmax(teacher45/2,dim=1),reduction='batchmean')*4
 return .3*distillation+.05*delta.square().mean()

def predicted_classes(values,present,margin=.5):
 prediction=values.argmax(1);ordered=np.sort(values,axis=1)
 return np.where(present & ((prediction==0)|(ordered[:,-1]-ordered[:,-2]>=margin)),prediction,0)

def require_detector_source(upstream,current):
 # A frozen detector remains reusable when its downstream classifier or unit
 # tests change. All detector/shared runtime sources must still match exactly.
 keys=[k for k in upstream if not k.startswith('tests/') and k!='tools/gesture_feature_adaptation.py']
 if any(current.get(k)!=upstream[k] for k in keys):raise ValueError('detector/shared source changed')

def cache(detector_cache,detector_experiment,out):
 if out.exists() or out.with_suffix('.json').exists():raise ValueError('new output only')
 torch.set_num_threads(2);info=validate(detector_cache);report=read(detector_experiment/'REPORT.json');sources=source_fingerprint(LAB)
 require_detector_source(report['source_sha256'],sources)
 if report['cache_sha256']!=sha(detector_cache) or report['head_sha256']!=sha(detector_experiment/'heads.npz'):raise ValueError('detector/cache changed')
 heads,_,_,_=reference_parts(Path(info['models']));restore_state(heads,detector_experiment/'heads.npz');heads.eval()
 with np.load(detector_cache,allow_pickle=False) as a:
  features=[torch.from_numpy(a[f'features{k}'].copy()) for k in range(4)];priors=torch.from_numpy(a['priors'].copy())
 reference,_,_=load_reference(Path(info['models']));images=[];metadata=[]
 rows=info['rows'];predictions=[]
 with torch.no_grad():
  for begin in range(0,len(rows),16):
   c,l=heads([f[begin:begin+16] for f in features])
   predictions.extend(best_detection(c[j],l[j],priors,.3) for j in range(len(c)))
 for row,prediction in zip(rows,predictions):
  with Image.open(row['path']) as im:rgb=center_rgb(im);size=im.size
  # No label/annotation supplied to automatic input selection.
  runtime=canonical_crop(rgb,prediction['box']) if prediction['box'] is not None else rgb
  runtime=reference.cv2.resize(runtime,(128,128),interpolation=reference.cv2.INTER_LINEAR)
  label={'open':1,'fist':2}[row['boxes'][0]['class']] if row['boxes'] else 0
  truth=record_box(row,size)
  common=dict(image=row['image'],path=row['path'],group=row['group'],origin=row['origin'],split=row['split'],
   expected=label,label_status=row['label_status'],negative_kind=row.get('negative_kind'))
  # A missed target cannot be recovered by a classifier in runtime inference.
  if row['split']=='val' or prediction['box'] is not None or label==0:
   images.append(runtime);metadata.append(dict(common,view='runtime',present=prediction['box'] is not None,
    predicted_box=prediction['box'],expected_box=truth if label else None,
    iou=normalized_iou(prediction['box'],truth) if prediction['box'] is not None and label else 0.))
  if truth is not None:
   oracle=reference.cv2.resize(canonical_crop(rgb,truth),(128,128),interpolation=reference.cv2.INTER_LINEAR)
   images.append(oracle);metadata.append(dict(common,view='annotation_crop',present=True,expected_box=truth,iou=1.))
 out.parent.mkdir(parents=True,exist_ok=True);np.savez_compressed(out,images=np.stack(images),labels=np.array([r['expected'] for r in metadata],np.int64))
 assert sources==source_fingerprint(LAB)
 result=dict(format='RGB128_RUNTIME_AND_TRAIN_ROI_V1',rows=metadata,cache_sha256=sha(out),source_sha256=sources,
  detector_report_sha256=sha(detector_experiment/'REPORT.json'),detector_heads_sha256=sha(detector_experiment/'heads.npz'),
  detector_cache=str(detector_cache.resolve()),models=info['models'],groups=project_groups(reference.labels),
  runtime_inputs_use_annotations=False,manual_val_crops_diagnostic_only=True,test_loaded=False,
  upstream_detector_source_sha256=report['source_sha256'])
 out.with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(dict(inputs=len(images),runtime_val=sum(r['split']=='val' and r['view']=='runtime' for r in metadata))),flush=True)

def tensor(images,augment=False):
 value=torch.from_numpy(images.astype(np.float32)).permute(0,3,1,2)
 if augment:
  flip=torch.rand(len(value))<.5;value[flip]=value[flip].flip(-1)
  gain=torch.empty(len(value),1,1,1).uniform_(.8,1.2);offset=torch.empty(len(value),1,1,1).uniform_(-20,20)
  value=(value*gain+offset).clamp(0,255)
 return (value-127)/128

def metrics(predicted,rows,ids):
 groups={}
 for group in sorted({rows[i]['group'] if rows[i]['origin']=='private' else 'public_val' for i in ids}):
  own=[i for i in ids if (rows[i]['group'] if rows[i]['origin']=='private' else 'public_val')==group]
  target=[i for i in own if rows[i]['expected']];negative=[i for i in own if not rows[i]['expected']]
  groups[group]=dict(targets=len(target),joint_correct=int(sum(predicted[i]==rows[i]['expected'] and rows[i]['iou']>=.5 for i in target)),
   negatives=len(negative),false_target=int(sum(predicted[i]!=0 for i in negative)),
   by_class={str(k):dict(total=sum(rows[i]['expected']==k for i in target),correct=int(sum(rows[i]['expected']==k and predicted[i]==k and rows[i]['iou']>=.5 for i in target))) for k in (1,2)})
 return groups

def selection_rank(groups):
 safe=all(v['false_target']<=PROTOCOL['public_false_target_fraction_limit']*v['negatives'] if group=='public_val' else v['false_target']==0 for group,v in groups.items())
 recalls=[v['correct']/v['total'] for domain in groups.values() for v in domain['by_class'].values() if v['total']]
 return (int(safe),min(recalls),float(np.mean(recalls)),-sum(v['false_target'] for v in groups.values()))

def train(cache_path,out,preserve_other=False):
 if out.exists():raise ValueError('new experiment only')
 torch.set_num_threads(2);torch.manual_seed(PROTOCOL['seed']);info=read(cache_path.with_suffix('.json'));sources=source_fingerprint(LAB)
 if info['source_sha256']!=sources or info['cache_sha256']!=sha(cache_path):raise ValueError('source/cache changed')
 validate(Path(info['detector_cache']));reference,backbone,parity=load_reference(Path(info['models']));model=TunableClassifier(backbone,info['groups'])
 teacher=copy.deepcopy(backbone).eval().requires_grad_(False) if preserve_other else None
 with np.load(cache_path,allow_pickle=False) as a:images=a['images'].copy();labels=torch.from_numpy(a['labels'].copy())
 rows=info['rows'];train_ids=[i for i,r in enumerate(rows) if r['split']=='train'];val_ids=[i for i,r in enumerate(rows) if r['split']=='val' and r['view']=='runtime']
 schedule=np.array([i for i in train_ids for _ in range(PROTOCOL['private_repeat'] if rows[i]['origin']=='private' else 1)])
 if any(r['label_status']!='reviewed' or r['split']=='test' for r in rows):raise ValueError('reviewed development only')
 weights=torch.from_numpy((len(schedule)/(3*np.bincount(labels[schedule],minlength=3))).astype(np.float32))
 optimizer=torch.optim.AdamW([dict(params=model.feature_parameters(),lr=PROTOCOL['backbone_lr']),dict(params=model.head.parameters(),lr=PROTOCOL['head_lr'])],weight_decay=PROTOCOL['weight_decay'])
 protocol=dict(PROTOCOL,preserve_other=preserve_other,negative_KL_temperature=2 if preserve_other else None,negative_KL_weight=.3 if preserve_other else 0,negative_delta_penalty=.05 if preserve_other else 0)
 out.mkdir(parents=True);(out/'FROZEN_PROTOCOL.json').write_text(json.dumps(dict(protocol=protocol,source_sha256=sources,cache_sha256=sha(cache_path)),indent=2)+'\n')
 rng=np.random.default_rng(PROTOCOL['seed']);best=None;rank=None;history=[];best_epoch=None;start=time.monotonic()
 def evaluate(ids):
  values=np.zeros((len(rows),3),np.float32);model.eval()
  with torch.no_grad():
   for begin in range(0,len(ids),12):
    own=ids[begin:begin+12];values[own]=model(tensor(images[own])).numpy()
  predicted=predicted_classes(values,np.array([r['present'] for r in rows]),.5)
  return values,predicted
 for epoch in range(PROTOCOL['epochs']):
  for p in model.feature_parameters():p.requires_grad_(epoch>=PROTOCOL['warmup_epochs'])
  model.train();losses=[]
  for own in np.array_split(rng.permutation(schedule),math.ceil(len(schedule)/PROTOCOL['batch_size'])):
   optimizer.zero_grad();inputs=tensor(images[own],True);values,raw45,delta=model.parts(inputs);loss=F.cross_entropy(values,labels[own],weight=weights)
   if teacher is not None:
    negative=labels[own]==0
    with torch.no_grad():teacher45=teacher(inputs[negative]) if negative.any() else raw45[negative].detach()
    loss=loss+preserve_negative_loss(raw45[negative],teacher45,delta[negative])
   loss.backward();nn.utils.clip_grad_norm_(model.parameters(),5);optimizer.step();losses.append(float(loss.detach()))
  if (epoch+1)%PROTOCOL['eval_every']==0:
   _,prediction=evaluate(val_ids);summary=metrics(prediction,rows,val_ids);candidate=selection_rank(summary)
   entry=dict(epoch=epoch+1,loss=float(np.mean(losses)),full_pipeline=summary,rank=list(candidate));history.append(entry);print(json.dumps(entry),flush=True)
   if rank is None or candidate>rank:rank=candidate;best=copy.deepcopy(model.state_dict());best_epoch=epoch+1
 model.load_state_dict(best);model.eval();all_val=[i for i,r in enumerate(rows) if r['split']=='val'];values,prediction=evaluate(all_val)
 summary=metrics(prediction,rows,val_ids);oracle={}
 for group in sorted({r['group'] if r['origin']=='private' else 'public_val' for r in rows if r['split']=='val'}):
  ids=[i for i,r in enumerate(rows) if r['split']=='val' and r['view']=='annotation_crop' and (r['group'] if r['origin']=='private' else 'public_val')==group]
  oracle[group]=measurements(values[ids],labels[ids].numpy(),.5)
 np.savez(out/'model.npz',**{k:v.detach().numpy() for k,v in model.state_dict().items()})
 report=dict(status='OFFLINE_FEATURE_FINETUNE_EXPERIMENT',protocol=protocol,source_sha256=sources,cache=str(cache_path.resolve()),cache_sha256=sha(cache_path),
  selected_epoch=best_epoch,head_sha256=sha(out/'model.npz'),full_pipeline=summary,oracle_crops=oracle,
  predictions=[dict(rows[i],predicted=int(prediction[i]),logits=values[i].tolist()) for i in all_val],
  history=history,elapsed_seconds=time.monotonic()-start,training_views=len(train_ids),training_draws_per_epoch=len(schedule),
  backbone_updated=True,private_val_used_for_selection=True,test_evaluated=False,fpga_deployed=False,board_tested=False,
  torch_onnx_initial_max_error=parity,approved_for_gesture_use=False)
 assert source_fingerprint(LAB)==sources
 (out/'REPORT.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(selected_epoch=best_epoch,full_pipeline=summary)),flush=True)

if __name__=='__main__':
 p=argparse.ArgumentParser();s=p.add_subparsers(dest='command',required=True)
 c=s.add_parser('cache');c.add_argument('--detector-cache',type=Path,required=True);c.add_argument('--detector-experiment',type=Path,required=True);c.add_argument('--out',type=Path,required=True)
 t=s.add_parser('train');t.add_argument('--cache',type=Path,required=True);t.add_argument('--out',type=Path,required=True);t.add_argument('--preserve-other',action='store_true')
 a=p.parse_args()
 if a.command=='cache':cache(a.detector_cache,a.detector_experiment,a.out)
 else:train(a.cache,a.out,a.preserve_other)
