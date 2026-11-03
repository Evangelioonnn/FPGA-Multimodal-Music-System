"""Offline dense-proposal voting and spatial IoU-quality adaptation.

Shares the pinned SSD backbone; quality supervision uses reviewed train boxes.
Inference takes pixels/proposals only. No FPGA resource qualification is implied.
"""
import argparse,copy,json,math,shutil,time
from pathlib import Path
import numpy as np
from PIL import Image
import torch
from torch import nn
from torch.nn import functional as F
from gesture_detector_adaptation import LAB,reference_parts,best_detection,decode,sha,read
from gesture_context_adaptation import (verify_proposals,detector_view,recover_box,
 ContextRejectHead,gate_prediction)
from gesture_feature_adaptation import restore_state,tensor,metrics
from gesture_roi_refinement import (frozen_classifier,feature_pair,encode_boxes,
 decode_boxes,aligned_giou)
from gesture_flip_consistency import mirror_pair,aggregate
from pretrained_reference import Reference,center_rgb,normalized_iou
from provenance import source_fingerprint

PROTOCOL=dict(seed=20261020,top_k=32,detector_threshold=.3,epochs=80,
 batch_size=16,lr=.0005,weight_decay=.01,private_repeat=3,eval_every=10,
 hidden=64,dropout=.1,quality_alpha=.75,quality_gamma=2.,regression_weight=.5,
 box_bounds=[.25,.25,.5,.5],vote_policies=['highest','vote8','vote32','vote32_strict'],
 vote_selection='reviewed train only; minimum domain localization then mean',
 quality_selection='development minimum domain localization then mean',
 preserve_detector_presence=True,test_evaluated=False,fpga_deployed=False)

def valid_box(box):
 return box is not None and np.isfinite(box).all() and 0<=box[0]<=1 and 0<=box[1]<=1 and 0<min(box[2:]) and max(box[2:])<=1.4

def pair_iou(boxes,truth):
 a0,a1=boxes[...,:2]-boxes[...,2:]/2,boxes[...,:2]+boxes[...,2:]/2
 b0,b1=truth[...,:2]-truth[...,2:]/2,truth[...,:2]+truth[...,2:]/2
 inter=(torch.minimum(a1,b1)-torch.maximum(a0,b0)).clamp(min=0).prod(-1)
 return inter/(boxes[...,2:].prod(-1)+truth[...,2:].prod(-1)-inter).clamp(min=1e-8)

def anchor_descriptor(maps,index):
 """Map a flattened SSD anchor to its own spatial feature, never global pooling."""
 offsets=0
 for level,(feature,anchors) in enumerate(zip(maps,(3,2,2,3))):
  _,channels,height,width=feature.shape;count=height*width*anchors
  if offsets<=index<offsets+count:
   cell=(index-offsets)//anchors;y,x=divmod(cell,width)
   out=np.zeros(256,np.float32);out[:channels]=feature[0,:,y,x]
   return out,level
  offsets+=count
 raise ValueError('anchor index outside feature maps')

def candidates(logits,locations,priors,maps,transform):
 scores=torch.softmax(logits,-1)[:,1];ids=torch.argsort(scores,descending=True,stable=True)[:32]
 decoded=decode(locations[ids],priors[ids]).detach().numpy();boxes=np.tile([.5,.5,.1,.1],(32,1)).astype(np.float32)
 features=np.zeros((32,265),np.float32);values=np.zeros(32,np.float32);valid=np.zeros(32,bool)
 for j,index in enumerate(ids.tolist()):
  box=recover_box(decoded[j],transform);score=float(scores[index])
  if score<.3 or not valid_box(box):continue
  vector,level=anchor_descriptor(maps,index);features[j,:256]=vector;features[j,256:260]=box
  features[j,260]=score;features[j,261+level]=1;boxes[j]=box;values[j]=score;valid[j]=True
 return boxes,values,valid,features

def box_vote(boxes,scores,valid,baseline,policy):
 if baseline is None:return None
 if policy=='highest':return list(baseline)
 if policy not in PROTOCOL['vote_policies']:raise ValueError('unknown vote policy')
 limit=8 if policy=='vote8' else 32;threshold=.7 if policy=='vote32_strict' else .5
 own=np.flatnonzero(valid)[:limit]
 own=[i for i in own if normalized_iou(boxes[i],baseline)>=threshold]
 if not own:return list(baseline)
 weight=np.square(scores[own].astype(np.float64));total=weight.sum()
 if total<=0:return list(baseline)
 # Center/width coordinates are a linear transform of xyxy, so voting is identical.
 return (np.sum(boxes[own]*weight[:,None],axis=0)/total).tolist()

def localization(rows,boxes,split):
 groups={}
 for r,b in zip(rows,boxes):
  if r['split']!=split:continue
  name=r['group'] if r['origin']=='private' else 'public';g=groups.setdefault(name,dict(targets=0,localized=0))
  if r['boxes']:
   g['targets']+=1;g['localized']+=int(b is not None and normalized_iou(b,r['detector_box'])>=.5)
 return groups

def location_rank(groups):
 values=[v['localized']/v['targets'] for v in groups.values() if v['targets']]
 if not values:raise ValueError('localization targets required')
 return min(values),float(np.mean(values))

def vote_selection(rows,boxes,scores,valid):
 result={};baseline=[r['baseline_box'] for r in rows]
 for policy in PROTOCOL['vote_policies']:
  own=[box_vote(b,s,v,p,policy) for b,s,v,p in zip(boxes,scores,valid,baseline)]
  met=localization(rows,own,'train');result[policy]=dict(groups=met,rank=location_rank(met))
 return max(PROTOCOL['vote_policies'],key=lambda p:result[p]['rank']),result

def dense_cache(proposal_path,out):
 if out.exists() or out.with_suffix('.json').exists():raise ValueError('new dense cache required')
 torch.set_num_threads(2);sources=source_fingerprint(LAB);p=verify_proposals(proposal_path)
 if any(sources.get(k)!=v for k,v in p['source_sha256'].items()):raise ValueError('upstream source changed')
 heads,session,priors,_=reference_parts(Path(p['models']));reference=Reference(Path(p['models']));priors=torch.from_numpy(priors)
 detector=LAB/'checkpoints/detector_head_adaptation_20261016/heads.npz'
 if sha(detector)!=p['detector_heads_sha256']:raise ValueError('detector changed')
 restore_state(heads,detector);heads.eval();all_boxes=[];all_scores=[];all_valid=[];all_features=[];rows=[]
 for i,(row,old) in enumerate(zip(p['rows'],p['predictions'])):
  with Image.open(row['path']) as im:rgb=center_rgb(im)
  image,transform=detector_view(rgb,'letterbox',reference);maps=session.run(None,{'input':reference.tensor(image,(320,240))})[:4]
  with torch.no_grad():c,l=heads([torch.from_numpy(v) for v in maps])
  base=best_detection(c[0],l[0],priors,.3);baseline=recover_box(base['box'],transform)
  if not valid_box(baseline):baseline=None
  if baseline is not None:np.testing.assert_allclose(baseline,old['letterbox']['box'],atol=1e-6)
  else:assert old['letterbox']['box'] is None
  b,s,v,f=candidates(c[0],l[0],priors,maps,transform)
  all_boxes.append(b);all_scores.append(s);all_valid.append(v);all_features.append(f);rows.append(dict(row,baseline_box=baseline))
  if (i+1)%160==0:print(json.dumps(dict(dense_images=i+1)),flush=True)
 boxes,scores,valid,features=map(np.stack,[all_boxes,all_scores,all_valid,all_features])
 policy,selection=vote_selection(rows,boxes,scores,valid);diagnostic={}
 for name in PROTOCOL['vote_policies']:
  predicted=[box_vote(b,s,v,r['baseline_box'],name) for b,s,v,r in zip(boxes,scores,valid,rows)]
  diagnostic[name]=localization(rows,predicted,'val')
 out.parent.mkdir(parents=True,exist_ok=True);np.savez_compressed(out,boxes=boxes,scores=scores,valid=valid,features=features)
 info=dict(format='SPATIAL_SSD_TOP32_V1',rows=rows,source_sha256=sources,cache_sha256=sha(out),
  proposal_path=str(proposal_path.resolve()),proposal_sha256=sha(proposal_path),models=p['models'],detector_heads_sha256=p['detector_heads_sha256'],
  selected_vote_policy=policy,train_vote_selection=selection,validation_localization=diagnostic,
  validation_used_for_vote_selection=False,runtime_uses_annotations=False,test_evaluated=False,protocol=PROTOCOL)
 assert sources==source_fingerprint(LAB)
 out.with_suffix('.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(dict(vote=policy,validation=diagnostic),indent=2),flush=True)

def validate_dense(cache_path):
 info=read(cache_path.with_suffix('.json'))
 if sha(cache_path)!=info['cache_sha256']:raise ValueError('dense cache changed')
 verify_proposals(Path(info['proposal_path']))
 if sha(Path(info['proposal_path']))!=info['proposal_sha256']:raise ValueError('proposals changed')
 return info

class QualityHead(nn.Module):
 def __init__(self):
  super().__init__();self.hidden=nn.Sequential(nn.Linear(265,64),nn.ReLU(),nn.Dropout(.1))
  self.quality=nn.Linear(64,1);self.box=nn.Linear(64,4);nn.init.zeros_(self.box.weight);nn.init.zeros_(self.box.bias)
 def forward(self,features):
  normalized=torch.cat([F.layer_norm(features[...,:256],(256,)),features[...,256:]],-1);h=self.hidden(normalized)
  return self.quality(h).squeeze(-1),torch.tanh(self.box(h))*features.new_tensor([.25,.25,.5,.5])

def quality_loss(logits,target,valid):
 probability=logits.sigmoid();weight=torch.where(target>0,target,.75*probability.square())
 losses=F.binary_cross_entropy_with_logits(logits,target,reduction='none')*weight
 return losses[valid].mean() if valid.any() else logits.sum()*0

def quality_boxes(rows,boxes,scores,valid,quality,deltas,refine=False):
 result=[]
 for i,r in enumerate(rows):
  baseline=r['baseline_box']
  if baseline is None:result.append(None);continue
  allowed=valid[i]&np.array([normalized_iou(b,baseline)>=.3 for b in boxes[i]])
  if not allowed.any():result.append(baseline);continue
  rank=np.where(allowed,quality[i]*scores[i],-np.inf);j=int(rank.argmax());box=boxes[i,j]
  if refine:box=decode_boxes(torch.tensor(box),torch.tensor(deltas[i,j])).numpy()
  result.append(box.tolist() if valid_box(box) else baseline)
 return result

def train_quality(cache_path,out):
 if out.exists():raise ValueError('new quality checkpoint required')
 torch.set_num_threads(2);torch.manual_seed(PROTOCOL['seed']);sources=source_fingerprint(LAB);info=validate_dense(cache_path)
 if sources!=info['source_sha256']:raise ValueError('dense source changed')
 with np.load(cache_path,allow_pickle=False) as a:boxes=a['boxes'].copy();scores=a['scores'].copy();valid=a['valid'].copy();features=torch.from_numpy(a['features'].copy())
 rows=info['rows'];ids=[i for i,r in enumerate(rows) if r['split']=='train' and r['detector_label_status']!='ignore']
 schedule=np.array([i for i in ids for _ in range(3 if rows[i]['origin']=='private' else 1)])
 truth=torch.tensor([r['detector_box'] if r['detector_box'] is not None else [.5,.5,.1,.1] for r in rows],dtype=torch.float32)
 b=torch.from_numpy(boxes);v=torch.from_numpy(valid);known=torch.tensor([r['detector_box'] is not None for r in rows])
 targets=pair_iou(b,truth[:,None]).clamp(0,1)*known[:,None];reg_mask=v&known[:,None]&(targets>=.25)
 model=QualityHead();optimizer=torch.optim.AdamW(model.parameters(),lr=.0005,weight_decay=.01);rng=np.random.default_rng(PROTOCOL['seed'])
 out.mkdir(parents=True)
 for rel in sources:
  path=out/'source'/rel;path.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(LAB/rel,path)
 (out/'FROZEN_PROTOCOL.json').write_text(json.dumps(dict(protocol=PROTOCOL,source_sha256=sources,cache_sha256=sha(cache_path)),indent=2)+'\n')
 history=[];best=None;best_rank=None;best_epoch=None;start=time.monotonic()
 for epoch in range(80):
  model.train();losses=[]
  for own in np.array_split(rng.permutation(schedule),math.ceil(len(schedule)/16)):
   optimizer.zero_grad();logits,deltas=model(features[own]);loss=quality_loss(logits,targets[own],v[own]);mask=reg_mask[own]
   if mask.any():
    truth_expanded=truth[own,None].expand(-1,32,-1);pred=decode_boxes(b[own][mask],deltas[mask]);expected=encode_boxes(b[own][mask],truth_expanded[mask])
    loss=loss+.5*(F.smooth_l1_loss(deltas[mask],expected,beta=.1)+(1-aligned_giou(pred,truth_expanded[mask])).mean())
   loss.backward();nn.utils.clip_grad_norm_(model.parameters(),5);optimizer.step();losses.append(float(loss.detach()))
  if (epoch+1)%10==0:
   model.eval()
   with torch.no_grad():q,d=model(features)
   chosen=quality_boxes(rows,boxes,scores,valid,q.sigmoid().numpy(),d.numpy(),True);summary=localization(rows,chosen,'val');rank=location_rank(summary)
   history.append(dict(epoch=epoch+1,loss=float(np.mean(losses)),validation=summary,rank=rank));print(json.dumps(history[-1]),flush=True)
   if best_rank is None or rank>best_rank:best=copy.deepcopy(model.state_dict());best_rank=rank;best_epoch=epoch+1
 model.load_state_dict(best);model.eval()
 with torch.no_grad():q,d=model(features)
 predictions={name:quality_boxes(rows,boxes,scores,valid,q.sigmoid().numpy(),d.numpy(),refine) for name,refine in [('quality',False),('refined',True)]}
 np.savez(out/'head.npz',**{k:v.detach().numpy() for k,v in model.state_dict().items()})
 result=dict(status='OFFLINE_SPATIAL_QUALITY',source_sha256=sources,protocol=PROTOCOL,cache_path=str(cache_path.resolve()),cache_sha256=sha(cache_path),
  head_sha256=sha(out/'head.npz'),selected_epoch=best_epoch,predictions=predictions,
  validation={name:localization(rows,value,'val') for name,value in predictions.items()},history=history,
  training_records=len(ids),training_draws_per_epoch=len(schedule),elapsed_seconds=time.monotonic()-start,
  private_val_used_for_selection=True,test_evaluated=False,fpga_deployed=False,board_tested=False,model_promoted=False)
 assert sources==source_fingerprint(LAB)
 (out/'REPORT.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(json.dumps(dict(epoch=best_epoch,validation=result['validation']),indent=2),flush=True)

def classifier_cache(dense_path,quality_dir,policy,out):
 if out.exists() or out.with_suffix('.json').exists():raise ValueError('new classifier cache required')
 torch.set_num_threads(2);sources=source_fingerprint(LAB);info=validate_dense(dense_path);report=read(quality_dir/'REPORT.json')
 if sha(quality_dir/'head.npz')!=report['head_sha256'] or report['cache_sha256']!=sha(dense_path):raise ValueError('quality identity changed')
 with np.load(dense_path,allow_pickle=False) as a:boxes=a['boxes'];scores=a['scores'];valid=a['valid']
 if policy=='vote':predicted=[box_vote(b,s,v,r['baseline_box'],info['selected_vote_policy']) for b,s,v,r in zip(boxes,scores,valid,info['rows'])]
 elif policy in ('quality','refined'):predicted=report['predictions'][policy]
 else:raise ValueError('unknown classifier geometry')
 reference,classifier,base_report=frozen_classifier(Path(info['models']),LAB/'checkpoints/feature_finetune_20261016')
 pending=[];all_features=[];all_base=[];metadata=[]
 def flush():
  if not pending:return
  with torch.no_grad():
   f=classifier.backbone.features(tensor(np.stack(pending)));raw=classifier.backbone.classifier(f)
   values=torch.stack([raw[:,g].max(1).values for g in classifier.groups],1)+classifier.head(F.layer_norm(f,(2048,)))
  n=len(pending)//4;all_features.extend(f.reshape(n,2,2,2048).numpy());all_base.extend(values.reshape(n,2,2,3)[:,:,0].numpy());pending.clear()
 for r,p in zip(info['rows'],predicted):
  with Image.open(r['path']) as image:rgb=center_rgb(image)
  expected={'open':1,'fist':2}[r['boxes'][0]['class']] if r['boxes'] else 0;truth=r['detector_box']
  common=dict(image=r['image'],path=r['path'],group=r['group'],origin=r['origin'],split=r['split'],
   expected=expected,label_status=r['label_status'],negative_kind=r.get('negative_kind'))
  def append(box,view):
   pair=feature_pair(rgb,box,reference);pending.extend(pair+mirror_pair(pair))
   metadata.append(dict(common,view=view,present=box is not None,predicted_box=box,expected_box=truth if expected else None,
    iou=normalized_iou(box,truth) if box is not None and expected else 0.))
   if len(pending)>=24:flush()
  if r['split']=='val' or p is not None or not expected:append(p,'runtime')
  if r['split']=='train' and truth is not None:append(truth,'annotation_crop')
 flush();out.parent.mkdir(parents=True,exist_ok=True)
 np.savez_compressed(out,features=np.stack(all_features),base_logits=np.stack(all_base),labels=np.array([r['expected'] for r in metadata],np.int64))
 result=dict(format='SPATIAL_PAIRED_CLASSIFIER_FEATURES_V1',rows=metadata,source_sha256=sources,cache_sha256=sha(out),
  proposal_path=info['proposal_path'],proposal_sha256=info['proposal_sha256'],dense_cache_sha256=sha(dense_path),
  quality_head_sha256=report['head_sha256'],policy=policy,selected_vote_policy=info['selected_vote_policy'],
  classifier_model_sha256=base_report['head_sha256'],runtime_uses_annotations=False,test_evaluated=False)
 frozen=ContextRejectHead();prior=LAB/'checkpoints/mirror_paired_20261016';restore_state(frozen,prior/'head.npz');frozen.eval()
 with torch.no_grad():values,rejection=frozen(torch.from_numpy(np.stack(all_features)).flatten(0,1),torch.from_numpy(np.stack(all_base)).flatten(0,1))
 values,rejection=aggregate(values.reshape(len(metadata),2,3),rejection.reshape(len(metadata),2,2))
 prediction=gate_prediction(values.numpy(),rejection.numpy(),np.array([r['present'] for r in metadata]),.85)
 result['frozen_classifier_validation']=metrics(prediction,metadata,[i for i,r in enumerate(metadata) if r['split']=='val'])
 assert sources==source_fingerprint(LAB)
 out.with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(dict(policy=policy,validation=result['frozen_classifier_validation']),indent=2),flush=True)

if __name__=='__main__':
 p=argparse.ArgumentParser();s=p.add_subparsers(dest='command',required=True)
 a=s.add_parser('dense');a.add_argument('--proposals',type=Path,required=True);a.add_argument('--out',type=Path,required=True)
 a=s.add_parser('train');a.add_argument('--cache',type=Path,required=True);a.add_argument('--out',type=Path,required=True)
 a=s.add_parser('classifier-cache');a.add_argument('--cache',type=Path,required=True);a.add_argument('--quality',type=Path,required=True);a.add_argument('--policy',choices=['vote','quality','refined'],required=True);a.add_argument('--out',type=Path,required=True)
 a=p.parse_args()
 if a.command=='dense':dense_cache(a.proposals,a.out)
 elif a.command=='train':train_quality(a.cache,a.out)
 else:classifier_cache(a.cache,a.quality,a.policy,a.out)
