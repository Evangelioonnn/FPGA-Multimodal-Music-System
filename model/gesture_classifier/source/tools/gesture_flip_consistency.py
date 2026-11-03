"""Offline mirrored-crop consistency with a bounded, pretrained-context head.

Two classifier views share one detector proposal. No second camera frame, GT
validation crop or additional manually labelled image is used for inference.
"""
import argparse,copy,json,math,shutil,time
from pathlib import Path
import numpy as np
from PIL import Image
import torch
from torch.nn import functional as F
from gesture_roi_refinement import (LAB,sha,read,verify_proposals,feature_pair,
 frozen_classifier,source_fingerprint,tensor)
from gesture_context_adaptation import ContextRejectHead,gate_prediction
from gesture_feature_adaptation import restore_state,metrics,selection_rank
from pretrained_reference import center_rgb

PROTOCOL=dict(seed=20261019,epochs=120,batch_size=32,lr=.0003,weight_decay=.01,
 private_repeat=3,eval_every=10,gate_thresholds=[0.,.5,.7,.85,.95],
 arms=['paired','consistent'],consistency_weight=.1,negative_prior_weight=.1,
 detector_views=1,classifier_views=2,aggregation='mean logits before decisions',
 correction_bound=2.,test_evaluated=False,fpga_deployed=False)

def mirror_pair(pair):
 return [np.ascontiguousarray(image[:,::-1]) for image in pair]

def symmetric_kl(a,b):
 loga,logb=F.log_softmax(a,-1),F.log_softmax(b,-1)
 return .5*((loga.exp()*(loga-logb)).sum(-1)+(logb.exp()*(logb-loga)).sum(-1)).mean()

def aggregate(values,rejection):
 if values.ndim!=3 or values.shape[1]!=2 or rejection.shape[:2]!=values.shape[:2]:raise ValueError('exactly two paired views required')
 return values.mean(1),rejection.mean(1)

def cache(context_cache,out):
 if out.exists() or out.with_suffix('.json').exists():raise ValueError('new paired cache required')
 torch.set_num_threads(2);sources=source_fingerprint(LAB);old=read(context_cache.with_suffix('.json'))
 if sha(context_cache)!=old['cache_sha256'] or any(sources.get(k)!=v for k,v in old['source_sha256'].items()):raise ValueError('context cache/source changed')
 p=verify_proposals(Path(old['proposal_path']))
 if sha(Path(old['proposal_path']))!=old['proposal_sha256']:raise ValueError('proposal identity changed')
 classifier=LAB/'checkpoints/feature_finetune_20261016';reference,model,report=frozen_classifier(Path(p['models']),classifier)
 lookup={(r['origin'],r['group'],r['image']):r for r in p['rows']}
 pending=[];features=[];base=[];rows=old['rows']
 def flush():
  if not pending:return
  with torch.no_grad():
   f=model.backbone.features(tensor(np.stack(pending)));raw=model.backbone.classifier(f)
   values=torch.stack([raw[:,g].max(1).values for g in model.groups],1)+model.head(F.layer_norm(f,(2048,)))
  n=len(pending)//2;features.extend(f.reshape(n,2,2048).numpy());base.extend(values.reshape(n,2,3)[:,0].numpy());pending.clear()
 for i,row in enumerate(rows):
  if row['view']=='runtime':box=row['predicted_box']
  elif row['split']=='train' and row['view']=='annotation_crop':box=lookup[(row['origin'],row['group'],row['image'])]['detector_box']
  else:raise ValueError('unexpected/non-runtime validation crop')
  with Image.open(row['path']) as image:rgb=center_rgb(image)
  pending.extend(mirror_pair(feature_pair(rgb,box,reference)))
  if len(pending)>=24:flush()
 flush()
 with np.load(context_cache,allow_pickle=False) as a:
  paired=np.stack([a['features'],np.stack(features)],1);paired_base=np.stack([a['base_logits'],np.stack(base)],1);labels=a['labels'].copy()
 out.parent.mkdir(parents=True,exist_ok=True);np.savez_compressed(out,features=paired,base_logits=paired_base,labels=labels)
 info=dict(format='PAIRED_MIRROR_CONTEXT_FEATURES_V1',rows=rows,source_sha256=sources,cache_sha256=sha(out),
  context_cache=str(context_cache.resolve()),context_cache_sha256=sha(context_cache),
  proposal_path=old['proposal_path'],proposal_sha256=old['proposal_sha256'],
  classifier_model_sha256=report['head_sha256'],runtime_uses_annotations=False,validation_views='deterministic runtime mirror of the same automatic crop',
  test_evaluated=False,protocol=PROTOCOL)
 assert sources==source_fingerprint(LAB)
 out.with_suffix('.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(dict(pairs=len(rows),views=2)),flush=True)

def evaluate(model,features,base):
 with torch.no_grad():values,rejection=model(features.flatten(0,1),base.flatten(0,1))
 return values.reshape(len(features),2,3),rejection.reshape(len(features),2,2)

def train(cache_path,prior_dir,out,arm):
 if out.exists() or arm not in PROTOCOL['arms']:raise ValueError('new paired experiment required')
 torch.set_num_threads(2);torch.manual_seed(PROTOCOL['seed']);sources=source_fingerprint(LAB);info=read(cache_path.with_suffix('.json'))
 if sources!=info['source_sha256'] or sha(cache_path)!=info['cache_sha256']:raise ValueError('paired source/cache changed')
 verify_proposals(Path(info['proposal_path']));prior_report=read(prior_dir/'REPORT.json')
 if sha(prior_dir/'head.npz')!=prior_report['head_sha256']:raise ValueError('prior changed')
 with np.load(cache_path,allow_pickle=False) as a:features=torch.from_numpy(a['features'].copy());base=torch.from_numpy(a['base_logits'].copy());labels=torch.from_numpy(a['labels'].copy())
 rows=info['rows'];ids=[i for i,r in enumerate(rows) if r['split']=='train'];val=[i for i,r in enumerate(rows) if r['split']=='val']
 if any(r['split']=='test' or r['label_status']!='reviewed' for r in rows) or any(rows[i]['view']!='runtime' for i in val):raise ValueError('reviewed train and automatic val only')
 schedule=np.array([i for i in ids for _ in range(3 if rows[i]['origin']=='private' else 1)])
 weights=torch.from_numpy((len(schedule)/(3*np.bincount(labels[schedule],minlength=3))).astype(np.float32))
 binary=labels.ne(0).long();bin_weights=torch.from_numpy((len(schedule)/(2*np.bincount(binary[schedule],minlength=2))).astype(np.float32))
 present=np.array([r['present'] for r in rows]);model=ContextRejectHead();restore_state(model,prior_dir/'head.npz')
 teacher=copy.deepcopy(model).eval().requires_grad_(False);teacher_values,teacher_rejection=evaluate(teacher,features,base)
 frozen_values,frozen_rejection=aggregate(teacher_values,teacher_rejection)
 frozen_pred=gate_prediction(frozen_values.numpy(),frozen_rejection.numpy(),present,.95)
 optimizer=torch.optim.AdamW(model.parameters(),lr=.0003,weight_decay=.01)
 out.mkdir(parents=True)
 for rel in sources:
  target=out/'source'/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(LAB/rel,target)
 protocol=dict(PROTOCOL,arm=arm,prior_sha256=prior_report['head_sha256'])
 (out/'FROZEN_PROTOCOL.json').write_text(json.dumps(dict(protocol=protocol,source_sha256=sources,cache_sha256=sha(cache_path)),indent=2)+'\n')
 rng=np.random.default_rng(PROTOCOL['seed']);history=[];best=None;best_rank=None;best_epoch=None;best_gate=None;start=time.monotonic()
 for epoch in range(120):
  model.train();losses=[]
  for own in np.array_split(rng.permutation(schedule),math.ceil(len(schedule)/32)):
   optimizer.zero_grad();values,rejection=model(features[own].flatten(0,1),base[own].flatten(0,1))
   loss=F.cross_entropy(values,labels[own].repeat_interleave(2),weight=weights)+F.cross_entropy(rejection,binary[own].repeat_interleave(2),weight=bin_weights)
   negative=labels[own].eq(0).repeat_interleave(2)
   if negative.any():
    teacher_v=teacher_values[own].flatten(0,1)[negative];teacher_r=teacher_rejection[own].flatten(0,1)[negative]
    loss=loss+.1*(F.mse_loss(values[negative],teacher_v)+F.mse_loss(rejection[negative],teacher_r))
   if arm=='consistent':
    v=values.reshape(len(own),2,3);r=rejection.reshape(len(own),2,2)
    loss=loss+.1*(symmetric_kl(v[:,0],v[:,1])+symmetric_kl(r[:,0],r[:,1]))
   loss.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),5);optimizer.step();losses.append(float(loss.detach()))
  if (epoch+1)%10==0:
   model.eval();v,r=evaluate(model,features,base);values,rejection=aggregate(v,r);alternatives=[]
   for threshold in PROTOCOL['gate_thresholds']:
    prediction=gate_prediction(values.numpy(),rejection.numpy(),present,threshold);summary=metrics(prediction,rows,val);rank=selection_rank(summary)
    alternatives.append(dict(gate=threshold,rank=list(rank),full_pipeline=summary))
    if best_rank is None or rank>best_rank:best=copy.deepcopy(model.state_dict());best_rank=rank;best_epoch=epoch+1;best_gate=threshold
   history.append(dict(epoch=epoch+1,loss=float(np.mean(losses)),alternatives=alternatives));print(json.dumps(history[-1]),flush=True)
 model.load_state_dict(best);model.eval();v,r=evaluate(model,features,base);values,rejection=aggregate(v,r)
 prediction=gate_prediction(values.numpy(),rejection.numpy(),present,best_gate);summary=metrics(prediction,rows,val)
 np.savez(out/'head.npz',**{k:v.detach().numpy() for k,v in model.state_dict().items()})
 result=dict(status='OFFLINE_PAIRED_MIRROR_CONTEXT',arm=arm,protocol=protocol,source_sha256=sources,cache_path=str(cache_path.resolve()),
  cache_sha256=sha(cache_path),head_sha256=sha(out/'head.npz'),selected_epoch=best_epoch,selected_gate=best_gate,selection_rank=list(best_rank),
  full_pipeline=summary,frozen_mirror_baseline=metrics(frozen_pred,rows,val),
  predictions=[dict(rows[i],predicted=int(prediction[i]),logits=values[i].tolist(),reject_logits=rejection[i].tolist()) for i in val],
  history=history,elapsed_seconds=time.monotonic()-start,private_val_used_for_selection=True,frozen_backbone=True,
  test_evaluated=False,fpga_deployed=False,board_tested=False,model_promoted=False)
 assert sources==source_fingerprint(LAB)
 (out/'REPORT.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(dict(arm=arm,epoch=best_epoch,gate=best_gate,full_pipeline=summary,frozen_mirror_baseline=result['frozen_mirror_baseline']),indent=2),flush=True)

if __name__=='__main__':
 p=argparse.ArgumentParser();s=p.add_subparsers(dest='command',required=True)
 a=s.add_parser('cache');a.add_argument('--context-cache',type=Path,required=True);a.add_argument('--out',type=Path,required=True)
 a=s.add_parser('train');a.add_argument('--cache',type=Path,required=True);a.add_argument('--prior',type=Path,required=True);a.add_argument('--out',type=Path,required=True);a.add_argument('--arm',choices=PROTOCOL['arms'],required=True)
 a=p.parse_args()
 if a.command=='cache':cache(a.context_cache,a.out)
 else:train(a.cache,a.prior,a.out,a.arm)
