"""Offline ROI jitter, box refinement and supervised contrastive comparison.

Uses reviewed train only for gradients; development val selects checkpoints.
This frozen-feature teacher is not an FPGA implementation or YOLO export.
"""
import argparse,copy,importlib.util,json,math,shutil,time
from pathlib import Path
import numpy as np
from PIL import Image
import torch
from torch import nn
from torch.nn import functional as F
from gesture_detector_adaptation import LAB,sha,read
from gesture_context_adaptation import (verify_proposals,choose_prediction,
 square_context,gate_prediction)
from gesture_feature_adaptation import restore_state,tensor,metrics,selection_rank
from pretrained_reference import center_rgb,normalized_iou
from pretrained_transfer import load_reference,project_groups,canonical_crop
from provenance import source_fingerprint

PROTOCOL=dict(seed=20261017,epochs=100,batch_size=48,lr=.001,box_lr=.0003,
 weight_decay=.01,private_repeat=3,eval_every=10,contexts=[1.,1.4],
 train_jitters=2,center_jitter=.15,log_size_jitter=.2,hidden=64,dropout=.15,
 correction_bound=4.,box_center_bound=.5,box_log_size_bound=.7,
 box_loss_weight=1.,contrastive_weight=.05,temperature=.1,
 gate_thresholds=[0.,.5,.7,.85,.95],reject_margin=.5,
 arms=['linear','mlp','supcon'],selection='unchanged development rejection eligibility then minimum domain/class joint recall',
 test_evaluated=False,fpga_deployed=False)

def jitter_boxes(box,split,seed,count=2):
 """Never create annotation-derived validation augmentations."""
 if split!='train' or box is None:return []
 rng=np.random.default_rng(seed);p=np.asarray(box,np.float64);out=[]
 for _ in range(count):
  b=p.copy();b[:2]+=rng.uniform(-.15,.15,2)*p[2:]
  b[2:]*=np.exp(rng.uniform(-.2,.2,2));b[:2]=np.clip(b[:2],0,1);b[2:]=np.clip(b[2:],1e-4,1.4)
  out.append(b.tolist())
 return out

def encode_boxes(proposals,truth):
 if proposals.shape!=truth.shape or proposals.shape[-1]!=4:raise ValueError('box shape mismatch')
 if not torch.isfinite(proposals).all() or not torch.isfinite(truth).all() or (proposals[...,2:]<=0).any() or (truth[...,2:]<=0).any():raise ValueError('invalid boxes')
 return torch.cat([(truth[...,:2]-proposals[...,:2])/proposals[...,2:],torch.log(truth[...,2:]/proposals[...,2:])],-1)

def decode_boxes(proposals,deltas):
 return torch.cat([proposals[...,:2]+deltas[...,:2]*proposals[...,2:],proposals[...,2:]*torch.exp(deltas[...,2:].clamp(-4,4))],-1)

def aligned_giou(a,b):
 a0,a1=a[...,:2]-a[...,2:]/2,a[...,:2]+a[...,2:]/2
 b0,b1=b[...,:2]-b[...,2:]/2,b[...,:2]+b[...,2:]/2
 intersection=(torch.minimum(a1,b1)-torch.maximum(a0,b0)).clamp(min=0).prod(-1)
 union=a[...,2:].prod(-1)+b[...,2:].prod(-1)-intersection
 enclosure=(torch.maximum(a1,b1)-torch.minimum(a0,b0)).clamp(min=0).prod(-1)
 return intersection/union.clamp(min=1e-8)-(enclosure-union)/enclosure.clamp(min=1e-8)

def refinement_loss(deltas,proposals,truth,mask):
 if not mask.any():return deltas.sum()*0
 pred=decode_boxes(proposals[mask],deltas[mask]);expected=encode_boxes(proposals[mask],truth[mask])
 return F.smooth_l1_loss(deltas[mask],expected,beta=.1)+(1-aligned_giou(pred,truth[mask])).mean()

def target_contrastive_loss(embedding,labels,image_ids,temperature=.1):
 """Targets cluster across images; diverse 'other' samples are negatives only."""
 if temperature<=0:raise ValueError('temperature must be positive')
 if len(embedding)<2:return embedding.sum()*0
 z=F.normalize(embedding,dim=-1);scores=z@z.T/temperature
 distinct=image_ids[:,None]!=image_ids[None,:]
 positive=(labels[:,None]==labels[None,:])&(labels[:,None]>0)&distinct
 valid=positive.any(1)&distinct.any(1)
 if not valid.any():return embedding.sum()*0
 # Avoid 0*inf on excluded/self pairs and all-same-image batches.
 scores=scores.masked_fill(~distinct,-1e4)
 log_prob=scores-torch.logsumexp(scores,1,keepdim=True)
 per=-(log_prob*positive).sum(1)/positive.sum(1).clamp(min=1)
 return per[valid].mean()

def frozen_classifier(models,experiment):
 report=read(experiment/'REPORT.json');runtime=experiment/'source/tools/gesture_feature_adaptation.py'
 if sha(experiment/'model.npz')!=report['head_sha256'] or sha(runtime)!=report['source_sha256']['tools/gesture_feature_adaptation.py']:raise ValueError('frozen classifier identity changed')
 spec=importlib.util.spec_from_file_location('frozen_refinement_classifier',runtime);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
 reference,backbone,_=load_reference(models);classifier=module.TunableClassifier(backbone,project_groups(reference.labels))
 restore_state(classifier,experiment/'model.npz');classifier.eval().requires_grad_(False)
 return reference,classifier,report

def feature_pair(rgb,box,reference):
 return [reference.cv2.resize(v,(128,128),interpolation=reference.cv2.INTER_LINEAR) for v in
  (canonical_crop(rgb,box) if box is not None else rgb,square_context(rgb,box,1.4))]

def cache(proposal_path,classifier_experiment,out):
 if out.exists() or out.with_suffix('.json').exists():raise ValueError('use a new cache')
 torch.set_num_threads(2);sources=source_fingerprint(LAB);p=verify_proposals(proposal_path)
 if any(sources.get(k)!=v for k,v in p['source_sha256'].items()):raise ValueError('upstream runtime changed')
 if p['policy']!='letterbox':raise ValueError('fixed preceding single-view geometry required')
 reference,classifier,report=frozen_classifier(Path(p['models']),classifier_experiment)
 pending=[];features=[];base=[];metadata=[]
 def flush():
  if not pending:return
  with torch.no_grad():
   f=classifier.backbone.features(tensor(np.stack(pending)));raw=classifier.backbone.classifier(f)
   scores=torch.stack([raw[:,g].max(1).values for g in classifier.groups],1)+classifier.head(F.layer_norm(f,(2048,)))
  n=len(pending)//2;features.extend(f.reshape(n,2,2048).numpy());base.extend(scores.reshape(n,2,3)[:,0].numpy());pending.clear()
 for index,(row,views) in enumerate(zip(p['rows'],p['predictions'])):
  proposal=choose_prediction(views,p['policy'])['box']
  with Image.open(row['path']) as im:rgb=center_rgb(im)
  # Only the automatically selected proposal reaches runtime preprocessing.
  pair=feature_pair(rgb,proposal,reference)
  expected={'open':1,'fist':2}[row['boxes'][0]['class']] if row['boxes'] else 0
  truth=row['detector_box'];common=dict(image=row['image'],image_id=index,path=row['path'],group=row['group'],origin=row['origin'],
   split=row['split'],expected=expected,label_status=row['label_status'],negative_kind=row.get('negative_kind'),
   expected_box=truth if expected else None)
  def append(box,view,pair=None):
   pending.extend(feature_pair(rgb,box,reference) if pair is None else pair)
   metadata.append(dict(common,view=view,present=box is not None,proposal=box,
    iou=normalized_iou(box,truth) if box is not None and expected else 0.))
   if len(pending)>=24:flush()
  if row['split']=='val' or proposal is not None or not expected:append(proposal,'runtime',pair)
  if row['split']=='train':
   if truth is not None:append(truth,'annotation_crop')
   seed_box=truth if truth is not None else proposal
   for box in jitter_boxes(seed_box,'train',PROTOCOL['seed']+index):append(box,'train_jitter')
  if (index+1)%150==0:print(json.dumps(dict(cached_sources=index+1,pairs=len(metadata))),flush=True)
 flush();out.parent.mkdir(parents=True,exist_ok=True)
 np.savez_compressed(out,features=np.stack(features),base_logits=np.stack(base),labels=np.array([r['expected'] for r in metadata],np.int64))
 result=dict(format='ROI_JITTER_REFINEMENT_FEATURES_V1',source_sha256=sources,rows=metadata,cache_sha256=sha(out),
  proposal_path=str(proposal_path.resolve()),proposal_sha256=sha(proposal_path),
  classifier_experiment=str(classifier_experiment.resolve()),classifier_model_sha256=report['head_sha256'],
  classifier_runtime_sha256=sha(classifier_experiment/'source/tools/gesture_feature_adaptation.py'),
  val_augmentation=False,runtime_uses_annotations=False,test_evaluated=False,protocol=PROTOCOL)
 assert sources==source_fingerprint(LAB)
 out.with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(dict(pairs=len(metadata),train=sum(r['split']=='train' for r in metadata),val=sum(r['split']=='val' for r in metadata))),flush=True)

class RefineHead(nn.Module):
 def __init__(self,arm):
  super().__init__()
  if arm not in PROTOCOL['arms']:raise ValueError('unknown arm')
  self.arm=arm;hidden=4096 if arm=='linear' else 64
  self.embedding=nn.Identity() if arm=='linear' else nn.Sequential(nn.Linear(4096,64),nn.LayerNorm(64),nn.GELU())
  self.dropout=nn.Identity() if arm=='linear' else nn.Dropout(.15)
  self.correction=nn.Linear(hidden,3);self.reject=nn.Linear(hidden,2);self.box=nn.Linear(4096,4)
  for layer in (self.correction,self.reject,self.box):nn.init.zeros_(layer.weight);nn.init.zeros_(layer.bias)

 def forward(self,features,base):
  normalized=F.layer_norm(features,(2048,)).flatten(1);embedding=self.embedding(normalized);active=self.dropout(embedding)
  bounds=normalized.new_tensor([.5,.5,.7,.7]);deltas=bounds*torch.tanh(self.box(normalized))
  return base+4*torch.tanh(self.correction(active)),self.reject(active),deltas,embedding

def refined_rows(rows,deltas):
 proposals=torch.tensor([r['proposal'] if r['proposal'] is not None else [.5,.5,1,1] for r in rows],dtype=torch.float32)
 boxes=decode_boxes(proposals,torch.as_tensor(deltas)).numpy()
 result=[]
 for r,b in zip(rows,boxes):
  own=dict(r);own['predicted_box']=b.tolist() if r['present'] else None
  own['iou']=normalized_iou(b,r['expected_box']) if r['expected'] and r['present'] else 0.
  result.append(own)
 return result

def train(cache_path,out,arm):
 if out.exists():raise ValueError('new checkpoint directory required')
 torch.set_num_threads(2);torch.manual_seed(PROTOCOL['seed']);sources=source_fingerprint(LAB);info=read(cache_path.with_suffix('.json'))
 if sources!=info['source_sha256'] or sha(cache_path)!=info['cache_sha256']:raise ValueError('source/cache changed')
 verify_proposals(Path(info['proposal_path']))
 if sha(Path(info['proposal_path']))!=info['proposal_sha256']:raise ValueError('proposals changed')
 with np.load(cache_path,allow_pickle=False) as a:features=torch.from_numpy(a['features'].copy());base=torch.from_numpy(a['base_logits'].copy());labels=torch.from_numpy(a['labels'].copy())
 rows=info['rows'];ids=[i for i,r in enumerate(rows) if r['split']=='train'];val=[i for i,r in enumerate(rows) if r['split']=='val']
 if any(r['label_status']!='reviewed' or r['split']=='test' for r in rows) or any(rows[i]['view']!='runtime' for i in val):raise ValueError('reviewed train / unaugmented val only')
 schedule=np.array([i for i in ids for _ in range(3 if rows[i]['origin']=='private' else 1)])
 weights=torch.from_numpy((len(schedule)/(3*np.bincount(labels[schedule],minlength=3))).astype(np.float32))
 binary=labels.ne(0).long();bin_weights=torch.from_numpy((len(schedule)/(2*np.bincount(binary[schedule],minlength=2))).astype(np.float32))
 proposals=torch.tensor([r['proposal'] if r['proposal'] is not None else [.5,.5,1,1] for r in rows],dtype=torch.float32)
 truth=torch.tensor([r['expected_box'] if r['expected_box'] is not None else [.5,.5,1,1] for r in rows],dtype=torch.float32)
 mask=torch.tensor([r['expected']>0 and r['present'] and r['iou']>=.25 for r in rows]);image_ids=torch.tensor([r['image_id'] for r in rows])
 present=np.array([r['present'] for r in rows]);model=RefineHead(arm)
 main=[p for name,p in model.named_parameters() if not name.startswith('box.')]
 optimizer=torch.optim.AdamW([dict(params=main,lr=.001),dict(params=model.box.parameters(),lr=.0003)],weight_decay=.01)
 out.mkdir(parents=True)
 for rel in sources:
  target=out/'source'/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(LAB/rel,target)
 (out/'FROZEN_PROTOCOL.json').write_text(json.dumps(dict(protocol=PROTOCOL,arm=arm,source_sha256=sources,cache_sha256=sha(cache_path)),indent=2)+'\n')
 rng=np.random.default_rng(PROTOCOL['seed']);history=[];best=None;best_rank=None;best_epoch=None;best_gate=None;start=time.monotonic()
 for epoch in range(100):
  model.train();losses=[]
  for own in np.array_split(rng.permutation(schedule),math.ceil(len(schedule)/48)):
   optimizer.zero_grad();values,rejection,deltas,embedding=model(features[own],base[own])
   loss=F.cross_entropy(values,labels[own],weight=weights)+F.cross_entropy(rejection,binary[own],weight=bin_weights)
   loss=loss+refinement_loss(deltas,proposals[own],truth[own],mask[own])
   if arm=='supcon':loss=loss+.05*target_contrastive_loss(embedding,labels[own],image_ids[own])
   loss.backward();nn.utils.clip_grad_norm_(model.parameters(),5);optimizer.step();losses.append(float(loss.detach()))
  if (epoch+1)%10==0:
   model.eval()
   with torch.no_grad():values,rejection,deltas,_=model(features,base)
   evaluated=refined_rows(rows,deltas.numpy());alternatives=[]
   for threshold in PROTOCOL['gate_thresholds']:
    prediction=gate_prediction(values.numpy(),rejection.numpy(),present,threshold);summary=metrics(prediction,evaluated,val);rank=selection_rank(summary)
    alternatives.append(dict(gate=threshold,rank=list(rank),full_pipeline=summary))
    if best_rank is None or rank>best_rank:best=copy.deepcopy(model.state_dict());best_rank=rank;best_epoch=epoch+1;best_gate=threshold
   history.append(dict(epoch=epoch+1,loss=float(np.mean(losses)),alternatives=alternatives));print(json.dumps(history[-1]),flush=True)
 model.load_state_dict(best);model.eval()
 with torch.no_grad():values,rejection,deltas,_=model(features,base)
 evaluated=refined_rows(rows,deltas.numpy());prediction=gate_prediction(values.numpy(),rejection.numpy(),present,best_gate)
 summary=metrics(prediction,evaluated,val);without=metrics(prediction,rows,val)
 np.savez(out/'head.npz',**{k:v.detach().numpy() for k,v in model.state_dict().items()})
 result=dict(status='OFFLINE_JITTER_REFINEMENT_COMPARISON',arm=arm,protocol=PROTOCOL,source_sha256=sources,
  cache_path=str(cache_path.resolve()),cache_sha256=sha(cache_path),head_sha256=sha(out/'head.npz'),
  selected_epoch=best_epoch,selected_gate=best_gate,selection_rank=list(best_rank),full_pipeline=summary,without_box_refinement=without,
  predictions=[dict(evaluated[i],predicted=int(prediction[i]),logits=values[i].tolist(),reject_logits=rejection[i].tolist(),deltas=deltas[i].tolist()) for i in val],
  history=history,elapsed_seconds=time.monotonic()-start,training_views=len(ids),training_draws_per_epoch=len(schedule),
  private_val_used_for_selection=True,frozen_backbone=True,test_evaluated=False,fpga_deployed=False,board_tested=False,model_promoted=False)
 assert sources==source_fingerprint(LAB)
 (out/'REPORT.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(dict(arm=arm,epoch=best_epoch,gate=best_gate,full_pipeline=summary),indent=2),flush=True)

if __name__=='__main__':
 p=argparse.ArgumentParser();s=p.add_subparsers(dest='command',required=True)
 a=s.add_parser('cache');a.add_argument('--proposals',type=Path,required=True);a.add_argument('--classifier-experiment',type=Path,required=True);a.add_argument('--out',type=Path,required=True)
 a=s.add_parser('train');a.add_argument('--cache',type=Path,required=True);a.add_argument('--out',type=Path,required=True);a.add_argument('--arm',choices=PROTOCOL['arms'],required=True)
 a=p.parse_args()
 if a.command=='cache':cache(a.proposals,a.classifier_experiment,a.out)
 else:train(a.cache,a.out,a.arm)
