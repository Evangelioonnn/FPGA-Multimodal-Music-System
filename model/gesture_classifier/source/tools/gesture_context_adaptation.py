"""Offline context/rejection experiment. Never a board-qualified YOLO export.

Fixed detector views are compared using TRAIN only. A shared frozen feature
extractor then supplies tight/wide crops to a learned rejection head. No labels
or human boxes enter automatic input selection.
"""
import argparse,copy,importlib.util,json,math,shutil,time
from pathlib import Path
import numpy as np
from PIL import Image
import torch
from torch import nn
from torch.nn import functional as F

from gesture_detector_adaptation import (LAB,development,detector_truth,
 reference_parts,best_detection,sha,read)
from gesture_feature_adaptation import (TunableClassifier,restore_state,
 require_detector_source,tensor,metrics,selection_rank,predicted_classes)
from pretrained_reference import Reference,center_rgb,normalized_iou
from pretrained_transfer import load_reference,project_groups,canonical_crop
from provenance import source_fingerprint

POLICIES=('stretch','stretch_flip','letterbox','letterbox_flip','all_highest')
PROTOCOL=dict(seed=20261016,epochs=120,batch_size=32,lr=.001,weight_decay=.01,
 private_repeat=3,contexts=[1.,1.4],residual_bound=2.,eval_every=10,
 gate_thresholds=[0.,.5,.7,.85,.95],reject_margin=.5,
 geometry_selection='train domains only; min localization minus mean true-background false detection',
 classifier_selection='development safety eligibility then min domain/class recall',
 frozen_features=True,test_evaluated=False)

def square_context(rgb,box,scale=1.):
 """Centered square with neutral padding; preserves visible edge fingers."""
 if not math.isfinite(scale) or scale<1:raise ValueError('context scale must be finite and >=1')
 if box is None:return rgb.copy()
 x,y,w,h=map(float,box);side=min(rgb.shape[:2])
 if not np.isfinite([x,y,w,h]).all() or min(w,h)<=0:raise ValueError('invalid context box')
 length=int(math.ceil(max(w,h)*side*scale))
 if length<=0 or length>side*2:raise ValueError('context crop too large')
 left=int(math.floor(x*side-length/2));top=int(math.floor(y*side-length/2))
 out=np.full((length,length,3),127,np.uint8)
 x0,y0=max(0,left),max(0,top);x1,y1=min(rgb.shape[1],left+length),min(rgb.shape[0],top+length)
 if x1>x0 and y1>y0:out[y0-top:y1-top,x0-left:x1-left]=rgb[y0:y1,x0:x1]
 return out

def detector_view(rgb,name,reference):
 """Return a model image and invertible (x scale, x offset, flip) metadata."""
 if name not in POLICIES[:-1]:raise ValueError('invalid view')
 if name.startswith('letterbox'):
  image=np.full((240,320,3),127,np.uint8)
  image[:,40:280]=reference.cv2.resize(rgb,(240,240),interpolation=reference.cv2.INTER_LINEAR)
  xscale,xoffset=.75,.125
 else:
  image=reference.cv2.resize(rgb,(320,240),interpolation=reference.cv2.INTER_LINEAR)
  xscale,xoffset=1.,0.
 flipped=name.endswith('_flip')
 if flipped:image=image[:,::-1].copy()
 return image,(xscale,xoffset,flipped)

def recover_box(box,transform):
 if box is None:return None
 x,y,w,h=map(float,box);scale,offset,flipped=transform
 if flipped:x=1-x
 return [(x-offset)/scale,y,w/scale,h]

def choose_prediction(views,policy):
 if policy not in POLICIES:raise ValueError('unknown view policy')
 choices=list(views.values()) if policy=='all_highest' else [views[policy]]
 choices=[p for p in choices if p['box'] is not None] or choices
 selected=max(choices,key=lambda p:p['score'])
 return copy.deepcopy(selected)

def domain_name(row):return row['group'] if row['origin']=='private' else 'public'

def localization(rows,predictions,split):
 groups={}
 for domain in sorted({domain_name(r) for r in rows if r['split']==split}):
  ids=[i for i,r in enumerate(rows) if r['split']==split and domain_name(r)==domain]
  targets=[i for i in ids if rows[i]['boxes']];background=[i for i in ids if rows[i]['detector_label_status']=='background']
  groups[domain]=dict(targets=len(targets),localized=sum(predictions[i]['box'] is not None and normalized_iou(predictions[i]['box'],rows[i]['detector_box'])>=.5 for i in targets),
   backgrounds=len(background),false_hand=sum(predictions[i]['box'] is not None for i in background))
 return groups

def choose_policy_on_train(rows,all_predictions):
 scores={}
 for policy in POLICIES:
  own=[choose_prediction(v,policy) for v in all_predictions]
  groups=localization(rows,own,'train')
  recalls=[v['localized']/v['targets'] for v in groups.values() if v['targets']]
  false=[v['false_hand']/v['backgrounds'] for v in groups.values() if v['backgrounds']]
  if not recalls:raise ValueError('policy selection requires training targets')
  scores[policy]=dict(groups=groups,rank=[min(recalls)-(float(np.mean(false)) if false else 0.),float(np.mean(recalls))])
 # Stable iteration favors simpler native geometry when tied.
 return max(POLICIES,key=lambda k:tuple(scores[k]['rank'])),scores

def proposals(public,private,models,detector_experiment,out):
 if out.exists():raise ValueError('use a new proposal file')
 torch.set_num_threads(2);sources=source_fingerprint(LAB);rows,identities=development(public,private)
 report=read(detector_experiment/'REPORT.json');require_detector_source(report['source_sha256'],sources)
 if report['head_sha256']!=sha(detector_experiment/'heads.npz'):raise ValueError('detector changed')
 heads,session,priors,_=reference_parts(models);restore_state(heads,detector_experiment/'heads.npz');heads.eval();priors=torch.from_numpy(priors)
 reference=Reference(models);predictions=[]
 with torch.no_grad():
  for i,row in enumerate(rows):
   with Image.open(row['path']) as im:rgb=center_rgb(im);size=im.size
   views={}
   for name in POLICIES[:-1]:
    image,transform=detector_view(rgb,name,reference)
    values=session.run(None,{'input':reference.tensor(image,(320,240))})
    c,l=heads([torch.from_numpy(v) for v in values[:4]])
    p=best_detection(c[0],l[0],priors,.3);p['box']=recover_box(p['box'],transform);p['view']=name
    if p['box'] is not None and (not 0<=p['box'][0]<=1 or not 0<=p['box'][1]<=1 or max(p['box'][2:])>1.4):p['box']=None
    views[name]=p
   predictions.append(views)
   # Labels are consulted only after automatic proposals have returned.
   truth,status=detector_truth(row,size);row['detector_box']=truth;row['detector_label_status']=status
   if (i+1)%100==0:print(json.dumps(dict(proposed=i+1)),flush=True)
 selected,selection=choose_policy_on_train(rows,predictions)
 diagnostic={policy:localization(rows,[choose_prediction(v,policy) for v in predictions],'val') for policy in POLICIES}
 result=dict(format='FOUR_VIEW_SINGLE_HAND_PROPOSALS_V1',rows=rows,predictions=predictions,
  policy=selected,train_selection=selection,validation_localization=diagnostic,identities=identities,
  source_sha256=sources,models=str(models.resolve()),detector_report_sha256=sha(detector_experiment/'REPORT.json'),
  detector_heads_sha256=report['head_sha256'],annotations_used_for_inference=False,validation_used_for_geometry_selection=False)
 assert sources==source_fingerprint(LAB)
 out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(dict(policy=selected,val=diagnostic[selected]),indent=2),flush=True)

def verify_proposals(path):
 info=read(path)
 for source in info['identities']:
  from dataset import load_records,fingerprint
  manifest=Path(source['path'])
  if fingerprint(manifest,load_records(manifest))!=source['identity']:raise ValueError('source image/labels changed')
 return info

def cache(proposal_path,classifier_experiment,out):
 if out.exists() or out.with_suffix('.json').exists():raise ValueError('new cache only')
 torch.set_num_threads(2);info=verify_proposals(proposal_path);sources=source_fingerprint(LAB)
 report=read(classifier_experiment/'REPORT.json')
 if report['head_sha256']!=sha(classifier_experiment/'model.npz'):raise ValueError('classifier changed')
 frozen_module='tools/gesture_feature_adaptation.py'
 for key,value in report['source_sha256'].items():
  if key.startswith('tests/'):continue
  if key==frozen_module:continue
  if sources.get(key)!=value:raise ValueError('frozen classifier runtime source changed')
 runtime_path=classifier_experiment/'source'/frozen_module
 if not runtime_path.exists():runtime_path=LAB/frozen_module
 if sha(runtime_path)!=report['source_sha256'][frozen_module]:raise ValueError('missing or modified classifier source snapshot')
 spec=importlib.util.spec_from_file_location('frozen_context_classifier',runtime_path)
 runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
 reference,backbone,_=load_reference(Path(info['models']))
 model=runtime.TunableClassifier(backbone,project_groups(reference.labels))
 restore_state(model,classifier_experiment/'model.npz');model.eval().requires_grad_(False)
 images=[];metadata=[];pending=[];features=[];base_logits=[]
 def flush():
  if not pending:return
  batch=np.stack(pending);count=len(batch)//2
  value=tensor(batch)
  with torch.no_grad():
   f=model.backbone.features(value);all45=model.backbone.classifier(f)
   base=torch.stack([all45[:,g].max(1).values for g in model.groups],1)+model.head(F.layer_norm(f,(2048,)))
  # Each pair is tight then wide, not batch halves.
  features.extend(f.reshape(count,2,2048).numpy());base_logits.extend(base.reshape(count,2,3)[:,0].numpy());pending.clear()
 for row,views in zip(info['rows'],info['predictions']):
  p=choose_prediction(views,info['policy'])
  with Image.open(row['path']) as im:rgb=center_rgb(im);size=im.size
  # Runtime selection precedes any use of expected labels or human boxes.
  runtime=(canonical_crop(rgb,p['box']) if p['box'] else rgb,square_context(rgb,p['box'],1.4))
  label={'open':1,'fist':2}[row['boxes'][0]['class']] if row['boxes'] else 0
  from roi_classifier import record_box
  truth=record_box(row,size)
  common=dict(image=row['image'],path=row['path'],group=row['group'],origin=row['origin'],split=row['split'],
   expected=label,label_status=row['label_status'],negative_kind=row.get('negative_kind'))
  def append(pair,details):
   pending.extend(reference.cv2.resize(v,(128,128),interpolation=reference.cv2.INTER_LINEAR) for v in pair)
   metadata.append(dict(common,**details))
   if len(pending)>=24:flush()
  if row['split']=='val' or p['box'] is not None or label==0:
   append(runtime,dict(view='runtime',present=p['box'] is not None,predicted_box=p['box'],expected_box=truth if label else None,
    iou=normalized_iou(p['box'],truth) if label and p['box'] is not None else 0.))
  if row['split']=='train' and truth is not None:
   append((canonical_crop(rgb,truth),square_context(rgb,truth,1.4)),dict(view='annotation_crop',present=True,iou=1.))
 flush();out.parent.mkdir(parents=True,exist_ok=True)
 np.savez_compressed(out,features=np.stack(features),base_logits=np.stack(base_logits),labels=np.array([r['expected'] for r in metadata],np.int64))
 result=dict(format='TIGHT_WIDE_FROZEN_FEATURES_V1',rows=metadata,source_sha256=sources,
  cache_sha256=sha(out),proposal_path=str(proposal_path.resolve()),proposal_sha256=sha(proposal_path),
  classifier_model_sha256=report['head_sha256'],classifier_report_sha256=sha(classifier_experiment/'REPORT.json'),
  classifier_runtime_sha256=sha(runtime_path),
  runtime_uses_annotations=False,test_evaluated=False,contexts=PROTOCOL['contexts'])
 assert sources==source_fingerprint(LAB)
 out.with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(dict(cached=len(metadata),runtime_val=sum(r['split']=='val' for r in metadata))),flush=True)

class ContextRejectHead(nn.Module):
 def __init__(self):
  super().__init__();self.correction=nn.Linear(4096,3);self.reject=nn.Linear(4096,2)
  for layer in (self.correction,self.reject):nn.init.zeros_(layer.weight);nn.init.zeros_(layer.bias)

 def forward(self,features,base):
  value=F.layer_norm(features,(2048,)).flatten(1)
  return base+2*torch.tanh(self.correction(value)),self.reject(value)

def gate_prediction(logits,rejection,present,threshold):
 pred=predicted_classes(logits,present,.5)
 probability=torch.softmax(torch.from_numpy(rejection),dim=1)[:,1].numpy()
 return np.where(probability>=threshold,pred,0)

def train(cache_path,out):
 if out.exists():raise ValueError('new experiment only')
 torch.set_num_threads(2);torch.manual_seed(PROTOCOL['seed']);sources=source_fingerprint(LAB);info=read(cache_path.with_suffix('.json'))
 if sources!=info['source_sha256'] or sha(cache_path)!=info['cache_sha256']:raise ValueError('source/cache changed')
 verify_proposals(Path(info['proposal_path']))
 if sha(Path(info['proposal_path']))!=info['proposal_sha256']:raise ValueError('proposals changed')
 with np.load(cache_path,allow_pickle=False) as a:
  features=torch.from_numpy(a['features'].copy());base=torch.from_numpy(a['base_logits'].copy());labels=torch.from_numpy(a['labels'].copy())
 rows=info['rows'];train_ids=[i for i,r in enumerate(rows) if r['split']=='train'];val_ids=[i for i,r in enumerate(rows) if r['split']=='val']
 if any(r['label_status']!='reviewed' or r['split']=='test' for r in rows):raise ValueError('reviewed development only')
 schedule=np.array([i for i in train_ids for _ in range(3 if rows[i]['origin']=='private' else 1)])
 cls_weights=torch.from_numpy((len(schedule)/(3*np.bincount(labels[schedule],minlength=3))).astype(np.float32))
 binary=labels.ne(0).long();bin_weights=torch.from_numpy((len(schedule)/(2*np.bincount(binary[schedule],minlength=2))).astype(np.float32))
 model=ContextRejectHead();optimizer=torch.optim.AdamW(model.parameters(),lr=.001,weight_decay=.01);rng=np.random.default_rng(PROTOCOL['seed'])
 out.mkdir(parents=True)
 for rel in sources:
  target=out/'source'/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(LAB/rel,target)
 (out/'FROZEN_PROTOCOL.json').write_text(json.dumps(dict(protocol=PROTOCOL,source_sha256=sources,cache_sha256=sha(cache_path)),indent=2)+'\n')
 history=[];best=None;best_rank=None;best_epoch=None;best_gate=None;start=time.monotonic()
 present=np.array([r['present'] for r in rows])
 for epoch in range(120):
  model.train();losses=[]
  for own in np.array_split(rng.permutation(schedule),math.ceil(len(schedule)/32)):
   optimizer.zero_grad();values,rejection=model(features[own],base[own]);loss=F.cross_entropy(values,labels[own],weight=cls_weights)+F.cross_entropy(rejection,binary[own],weight=bin_weights)
   loss.backward();nn.utils.clip_grad_norm_(model.parameters(),5);optimizer.step();losses.append(float(loss.detach()))
  if (epoch+1)%10==0:
   model.eval()
   with torch.no_grad():values,rejection=model(features,base)
   alternatives=[]
   for threshold in PROTOCOL['gate_thresholds']:
    pred=gate_prediction(values.numpy(),rejection.numpy(),present,threshold);summary=metrics(pred,rows,val_ids);rank=selection_rank(summary)
    alternatives.append(dict(gate=threshold,rank=list(rank),full_pipeline=summary))
    if best_rank is None or rank>best_rank:
     best_rank=rank;best_epoch=epoch+1;best_gate=threshold;best=copy.deepcopy(model.state_dict())
   history.append(dict(epoch=epoch+1,loss=float(np.mean(losses)),alternatives=alternatives));print(json.dumps(history[-1]),flush=True)
 model.load_state_dict(best);model.eval()
 with torch.no_grad():values,rejection=model(features,base)
 pred=gate_prediction(values.numpy(),rejection.numpy(),present,best_gate);summary=metrics(pred,rows,val_ids)
 np.savez(out/'head.npz',**{k:v.detach().numpy() for k,v in model.state_dict().items()})
 result=dict(status='OFFLINE_DUAL_CONTEXT_REJECTION_EXPERIMENT',protocol=PROTOCOL,source_sha256=sources,
  cache_path=str(cache_path.resolve()),cache_sha256=sha(cache_path),head_sha256=sha(out/'head.npz'),
  selected_epoch=best_epoch,selected_gate=best_gate,selection_rank=list(best_rank),full_pipeline=summary,
  predictions=[dict(rows[i],predicted=int(pred[i]),logits=values[i].tolist(),reject_logits=rejection[i].tolist()) for i in val_ids],
  history=history,elapsed_seconds=time.monotonic()-start,frozen_backbone=True,private_val_used_for_selection=True,
  training_views=len(train_ids),training_draws_per_epoch=len(schedule),test_evaluated=False,fpga_deployed=False,board_tested=False,model_promoted=False)
 assert sources==source_fingerprint(LAB)
 (out/'REPORT.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(dict(epoch=best_epoch,gate=best_gate,full_pipeline=summary),indent=2),flush=True)

if __name__=='__main__':
 p=argparse.ArgumentParser();s=p.add_subparsers(dest='command',required=True)
 a=s.add_parser('proposals');a.add_argument('--public',type=Path,required=True);a.add_argument('--private',type=Path,required=True);a.add_argument('--models',type=Path,required=True);a.add_argument('--detector-experiment',type=Path,required=True);a.add_argument('--out',type=Path,required=True)
 a=s.add_parser('cache');a.add_argument('--proposals',type=Path,required=True);a.add_argument('--classifier-experiment',type=Path,required=True);a.add_argument('--out',type=Path,required=True)
 a=s.add_parser('train');a.add_argument('--cache',type=Path,required=True);a.add_argument('--out',type=Path,required=True)
 a=p.parse_args()
 if a.command=='proposals':proposals(a.public,a.private,a.models,a.detector_experiment,a.out)
 elif a.command=='cache':cache(a.proposals,a.classifier_experiment,a.out)
 else:train(a.cache,a.out)
