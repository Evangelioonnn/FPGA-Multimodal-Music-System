"""Offline hand-detector adaptation. Not a Gowin/YOLO hardware export.

Reuses hash-pinned HaGRID-author RFB/SSD feature maps and learns SSD heads.
SSD matching / hard-negative mining are independently implemented from the
documented SSD method (see DETECTOR_FEATURE_ADAPTATION_2026-10-16.md).
"""
import argparse,copy,hashlib,json,math,time
from pathlib import Path
import numpy as np
from PIL import Image
import torch
from torch import nn
from torch.nn import functional as F
from dataset import load_records,fingerprint,training_partitions
from domain_adaptation import check_isolation
from pretrained_reference import Reference,center_rgb,normalized_iou,verify
from provenance import source_fingerprint
from roi_classifier import record_box

LAB=Path(__file__).resolve().parents[1]
RAW_CLASS='/predictor/net/Concat_8_output_0'
RAW_LOCATION='/predictor/net/Concat_9_output_0'
PROTOCOL=dict(seed=20261016,epochs=30,batch_size=16,lr=.0003,weight_decay=.0001,
 match_iou=.35,neg_pos_ratio=3,empty_negatives=32,score_threshold=.3,nms_iou=.3,
 private_repeat=3,eval_every=5,selection='minimum domain target localization minus mean no-hand false detection')
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
read=lambda p:json.loads(Path(p).read_text(encoding='utf-8'))

def development(public,private):
 sources=[];rows=[]
 for origin,path in [('public',Path(public)),('private',Path(private))]:
  own=load_records(path);training_partitions(own,pilot=True)
  if any(r.get('label_status')!='reviewed' or r['split']=='test' for r in own):raise ValueError('reviewed development only')
  sources.append((path,own))
  for r in own:rows.append(dict(r,origin=origin,path=str((path.parent/r['image']).resolve())))
 check_isolation(sources)
 return rows,[dict(path=str(p.resolve()),identity=fingerprint(p,r)) for p,r in sources]

def detector_truth(row,size):
 box=record_box(row,size)
 if box is not None:
  x,y,w,h=box
  if min(x-w/2,y-h/2)<-1e-6 or max(x+w/2,y+h/2)>1+1e-6:return None,'ignore'
  return box,'hand'
 known={'person_present_no_hand','empty_scene','complete_roi_without_annotated_hand',
        'full_frame_no_target_candidate','legacy_background_crop'}
 if row.get('negative_kind') in known or ('empty' in row.get('source_video','').lower()):return None,'background'
 # Other gestures / held objects can contain hands without hand annotations.
 return None,'ignore'

class SSDHeads(nn.Module):
 def __init__(self,arrays):
  super().__init__();self.classifiers=nn.ModuleList();self.regressors=nn.ModuleList()
  for level,channels in enumerate((64,128,256,256)):
   for kind,modules,dimensions in [('classification',self.classifiers,2),('regression',self.regressors,4)]:
    prefix=f'net.{kind}_headers.{level}';anchors=(3,2,2,3)[level]
    if level<3:
     layer=nn.Sequential(nn.Conv2d(channels,channels,3,padding=1,groups=channels),nn.ReLU(),nn.Conv2d(channels,anchors*dimensions,1))
     targets=[(layer[0],prefix+'.0'),(layer[2],prefix+'.2')]
    else:
     layer=nn.Conv2d(channels,anchors*dimensions,3,padding=1);targets=[(layer,prefix)]
    for module,key in targets:
     with torch.no_grad():
      module.weight.copy_(torch.from_numpy(np.array(arrays[key+'.weight'],copy=True)))
      module.bias.copy_(torch.from_numpy(np.array(arrays[key+'.bias'],copy=True)))
    modules.append(layer)

 def forward(self,features):
  classes=[];locations=[]
  for x,c,r in zip(features,self.classifiers,self.regressors):
   classes.append(c(x).permute(0,2,3,1).reshape(x.shape[0],-1,2))
   locations.append(r(x).permute(0,2,3,1).reshape(x.shape[0],-1,4))
  return torch.cat(classes,1),torch.cat(locations,1)

def reference_parts(models):
 import onnx
 from onnx import numpy_helper,helper,TensorProto
 import onnxruntime as ort
 verify(models);model=onnx.load(str(models/'models/hand_detector.onnx'),load_external_data=False)
 arrays={t.name:numpy_helper.to_array(t) for t in model.graph.initializer}
 names=[]
 for level in range(4):
  node=next(n for n in model.graph.node if n.op_type=='Conv' and n.name.startswith(f'/predictor/net/classification_headers.{level}/'))
  names.append(node.input[0])
 outputs=names+[RAW_CLASS,RAW_LOCATION]
 # Extract exactly the known graph. The original model is never mutated.
 graph=onnx.utils.Extractor(model).extract_model(['input'],outputs)
 options=ort.SessionOptions();options.intra_op_num_threads=2;options.inter_op_num_threads=1
 session=ort.InferenceSession(graph.SerializeToString(),sess_options=options,providers=['CPUExecutionProvider'])
 priors=np.concatenate([arrays['/predictor/net/Constant_31_output_0'][0],arrays['/predictor/net/Constant_30_output_0'][0]],1).copy()
 return SSDHeads(arrays),session,priors,float(arrays['/predictor/Constant_1_output_0'])

def decode(locations,priors):
 center=locations[...,:2]*.1*priors[:,2:]+priors[:,:2]
 size=torch.exp(locations[...,2:].clamp(-20,20)*.2)*priors[:,2:]
 return torch.cat([center,size],-1)

def anchor_iou(priors,box):
 a0=priors[:,:2]-priors[:,2:]/2;a1=priors[:,:2]+priors[:,2:]/2
 b0=box[:2]-box[2:]/2;b1=box[:2]+box[2:]/2
 inter=(torch.minimum(a1,b1)-torch.maximum(a0,b0)).clamp(min=0).prod(-1)
 return inter/(priors[:,2:].prod(-1)+box[2:].prod()-inter).clamp(min=1e-9)

def match(priors,box):
 labels=torch.zeros(len(priors),dtype=torch.long);locations=torch.zeros_like(priors)
 if box is None:return labels,locations
 box=torch.as_tensor(box,dtype=torch.float32);overlap=anchor_iou(priors,box)
 labels[overlap>=PROTOCOL['match_iou']]=1;labels[overlap.argmax()]=1
 locations[:,:2]=(box[:2]-priors[:,:2])/priors[:,2:]/.1
 locations[:,2:]=torch.log(box[2:]/priors[:,2:])/.2
 return labels,locations

def multibox_loss(logits,locations,labels,truth):
 positive=labels.bool();npositive=positive.sum(1)
 ce=F.cross_entropy(logits.reshape(-1,2),labels.reshape(-1),reduction='none').reshape_as(labels)
 with torch.no_grad():
  ranks=ce.detach().masked_fill(positive,-float('inf')).argsort(1,descending=True).argsort(1)
  count=torch.where(npositive>0,npositive*3,torch.full_like(npositive,PROTOCOL['empty_negatives']))
  negative=(ranks<count[:,None])&~positive
 denominator=npositive.sum().clamp(min=len(logits))
 classification=ce[positive|negative].sum()/denominator
 regression=F.smooth_l1_loss(locations[positive],truth[positive],reduction='sum')/denominator
 return classification+regression

def best_detection(logits,locations,priors,threshold=.3):
 # Highest score is identical before/after greedy NMS; the project uses one hand.
 scores=torch.softmax(logits,dim=-1)[...,1];index=int(scores.argmax());score=float(scores[index])
 if score<threshold:return dict(box=None,score=score)
 box=decode(locations[index:index+1],priors[index:index+1])[0].tolist()
 if not np.isfinite(box).all() or min(box[2:])<=0:return dict(box=None,score=score)
 return dict(box=box,score=score)

def cache(public,private,models,out):
 if out.exists() or out.with_suffix('.json').exists():raise ValueError('new output only')
 torch.set_num_threads(2);sources=source_fingerprint(LAB);rows,identities=development(public,private)
 heads,session,priors,internal=reference_parts(models);reference=Reference(models)
 rng=np.random.default_rng(18);max_error=0.
 for image in [np.zeros((240,320,3),np.uint8),rng.integers(0,256,(240,320,3),np.uint8)]:
  values=session.run(None,{'input':reference.tensor(image,(320,240))})
  with torch.no_grad():actual=heads([torch.from_numpy(v) for v in values[:4]])
  for a,e in zip(actual,values[4:]):
   np.testing.assert_allclose(a.numpy(),e,atol=1e-4,rtol=1e-4);max_error=max(max_error,float(np.abs(a.numpy()-e).max()))
 feature_lists=[[] for _ in range(4)];metadata=[]
 for i,row in enumerate(rows):
  with Image.open(row['path']) as image:
   rgb=center_rgb(image);truth,status=detector_truth(row,image.size)
  values=session.run(None,{'input':reference.tensor(rgb,(320,240))})
  for k in range(4):feature_lists[k].append(values[k][0])
  metadata.append(dict(row,detector_box=truth,detector_label_status=status))
  if (i+1)%100==0:print(json.dumps(dict(cached=i+1)),flush=True)
 out.parent.mkdir(parents=True,exist_ok=True)
 np.savez_compressed(out,**{f'features{k}':np.stack(v) for k,v in enumerate(feature_lists)},priors=priors)
 info=dict(format='FROZEN_RFB_SSD_FEATURES_V1',rows=metadata,identities=identities,
  source_sha256=sources,cache_sha256=sha(out),original_internal_threshold=internal,
  heads_parity_max_error=max_error,models=str(models.resolve()),test_loaded=False)
 assert sources==source_fingerprint(LAB)
 out.with_suffix('.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(dict(cached=len(rows),heads_parity=max_error,hidden_threshold=internal)),flush=True)

def validate(cache_path):
 info=read(cache_path.with_suffix('.json'))
 if info['cache_sha256']!=sha(cache_path):raise ValueError('cache changed')
 for source in info['identities']:
  path=Path(source['path'])
  if source['identity']!=fingerprint(path,load_records(path)):raise ValueError('source changed')
 return info

def evaluate(heads,features,priors,rows,indices,threshold):
 predictions=[]
 with torch.no_grad():
  for begin in range(0,len(indices),16):
   own=indices[begin:begin+16];c,l=heads([f[own] for f in features])
   for j,i in enumerate(own):predictions.append(dict(index=int(i),**best_detection(c[j],l[j],priors,threshold)))
 groups={}
 for group in sorted({rows[i]['group'] if rows[i]['origin']=='private' else 'public_val' for i in indices}):
  own=[p for p in predictions if (rows[p['index']]['group'] if rows[p['index']]['origin']=='private' else 'public_val')==group]
  target=[p for p in own if rows[p['index']]['boxes']];background=[p for p in own if rows[p['index']]['detector_label_status']=='background']
  groups[group]=dict(targets=len(target),localized=sum(p['box'] is not None and normalized_iou(p['box'],rows[p['index']]['detector_box'])>=.5 for p in target),
   true_no_hand=len(background),false_hand=sum(p['box'] is not None for p in background))
 return groups,predictions

def train(cache_path,out):
 if out.exists():raise ValueError('new experiment only')
 torch.set_num_threads(2);torch.manual_seed(PROTOCOL['seed']);info=validate(cache_path);sources=source_fingerprint(LAB)
 if sources!=info['source_sha256']:raise ValueError('code changed after caching')
 heads,_,_,_=reference_parts(Path(info['models']))
 with np.load(cache_path,allow_pickle=False) as a:
  features=[torch.from_numpy(a[f'features{k}'].copy()) for k in range(4)];priors=torch.from_numpy(a['priors'].copy())
 rows=info['rows'];train_ids=[i for i,r in enumerate(rows) if r['split']=='train' and r['detector_label_status']!='ignore'];val_ids=[i for i,r in enumerate(rows) if r['split']=='val']
 schedule=np.array([i for i in train_ids for _ in range(PROTOCOL['private_repeat'] if rows[i]['origin']=='private' else 1)])
 labels=[];locations=[]
 for r in rows:
  a,b=match(priors,r['detector_box']);labels.append(a);locations.append(b)
 labels,truth=torch.stack(labels),torch.stack(locations)
 out.mkdir(parents=True);(out/'FROZEN_PROTOCOL.json').write_text(json.dumps(dict(protocol=PROTOCOL,source_sha256=sources,cache_sha256=sha(cache_path)),indent=2)+'\n')
 baseline,predictions=evaluate(heads,features,priors,rows,val_ids,.7)
 corrected,_=evaluate(heads,features,priors,rows,val_ids,.3)
 optimizer=torch.optim.AdamW(heads.parameters(),lr=PROTOCOL['lr'],weight_decay=PROTOCOL['weight_decay']);rng=np.random.default_rng(PROTOCOL['seed'])
 history=[];best=None;rank=None;best_epoch=None;start=time.monotonic()
 for epoch in range(PROTOCOL['epochs']):
  heads.train();losses=[]
  for own in np.array_split(rng.permutation(schedule),math.ceil(len(schedule)/PROTOCOL['batch_size'])):
   optimizer.zero_grad();c,l=heads([f[own] for f in features]);loss=multibox_loss(c,l,labels[own],truth[own]);loss.backward();nn.utils.clip_grad_norm_(heads.parameters(),5);optimizer.step();losses.append(float(loss.detach()))
  if (epoch+1)%PROTOCOL['eval_every']==0:
   heads.eval();summary,_=evaluate(heads,features,priors,rows,val_ids,.3)
   recalls=[v['localized']/v['targets'] for v in summary.values() if v['targets']];false=[v['false_hand']/v['true_no_hand'] for v in summary.values() if v['true_no_hand']]
   value=(min(recalls)-np.mean(false),np.mean(recalls),-np.mean(false))
   entry=dict(epoch=epoch+1,loss=float(np.mean(losses)),validation=summary,rank=list(map(float,value)));history.append(entry);print(json.dumps(entry),flush=True)
   if rank is None or value>rank:rank=value;best=copy.deepcopy(heads.state_dict());best_epoch=epoch+1
 heads.load_state_dict(best);heads.eval();summary,predictions=evaluate(heads,features,priors,rows,val_ids,.3)
 arrays={k:v.detach().numpy() for k,v in heads.state_dict().items()};np.savez(out/'heads.npz',**arrays)
 result=dict(status='OFFLINE_DETECTOR_HEAD_ADAPTATION',protocol=PROTOCOL,source_sha256=sources,cache=str(cache_path.resolve()),cache_sha256=sha(cache_path),
  baseline_internal07=baseline,corrected_threshold03=corrected,adapted=summary,predictions=predictions,
  selected_epoch=best_epoch,head_sha256=sha(out/'heads.npz'),history=history,elapsed_seconds=time.monotonic()-start,
  training_images=len(train_ids),ignored_training_records=sum(r['split']=='train' and r['detector_label_status']=='ignore' for r in rows),
  backbone_frozen=True,private_val_used_for_selection=True,test_evaluated=False,fpga_deployed=False,board_tested=False)
 assert sources==source_fingerprint(LAB)
 (out/'REPORT.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(dict(selected_epoch=best_epoch,adapted=summary)),flush=True)

if __name__=='__main__':
 p=argparse.ArgumentParser();sub=p.add_subparsers(dest='command',required=True)
 c=sub.add_parser('cache');c.add_argument('--public',type=Path,required=True);c.add_argument('--private',type=Path,required=True);c.add_argument('--models',type=Path,required=True);c.add_argument('--out',type=Path,required=True)
 t=sub.add_parser('train');t.add_argument('--cache',type=Path,required=True);t.add_argument('--out',type=Path,required=True)
 a=p.parse_args()
 if a.command=='cache':cache(a.public,a.private,a.models,a.out)
 else:train(a.cache,a.out)
