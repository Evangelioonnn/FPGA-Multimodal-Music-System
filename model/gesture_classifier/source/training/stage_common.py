"""Pinned offline two-stage comparison. No serial, Programmer, network or test input."""
import hashlib
import json
from pathlib import Path
import sys
import numpy as np
from PIL import Image

HERE=Path(__file__).resolve().parent;LAB=HERE.parent;ROOT=LAB.parents[1]
sys.path[:0]=[str(ROOT/'tmp/torch_cpu'),str(ROOT/'tmp/onnx_reference'),str(ROOT/'tmp/opencv_reference'),str(LAB/'tools')]
import torch
from torch import nn
from torch.nn import functional as F
from pretrained_transfer import load_reference
from pretrained_reference import center_rgb,normalized_iou
from gesture_context_adaptation import square_context,detector_view,recover_box
from gesture_localizer_backbone import TailDetector,box_from_heads

WORK=LAB/'work/two_stage_transfer_20261022'
FIXED=LAB/'work/crop_structure_20261020'
CHECKPOINT=LAB/'checkpoints/feature_rejection_20261020/feature_ce/weights.pt'
MODEL_DIR=LAB/'model_export/reference_dynamic_557a_20261016'
SEED=20261025
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def read(p):return json.loads(Path(p).read_text(encoding='utf-8-sig'))
def write(p,d):Path(p).write_text(json.dumps(d,indent=2)+'\n',encoding='utf-8')
def gray(rgb):
    a=rgb.astype(np.uint16);return ((77*a[...,0]+150*a[...,1]+29*a[...,2])>>8).astype(np.uint8)
def floor_sample(a,size):
    h,w=a.shape[:2];return a[(np.arange(size)*h//size)[:,None],(np.arange(size)*w//size)[None,:]].copy()
def repeat(a):return np.repeat(a[...,None],3,axis=2)
def teacher_tensor(a):return (torch.from_numpy(np.stack(a)).permute(0,3,1,2).float()-127)/128
def decide(logits,boxes):
    ordered=np.sort(logits,axis=1);top=logits.argmax(1)
    return np.where((ordered[:,-1]-ordered[:,-2]>=.5)&np.array([b is not None for b in boxes]),top,0)

def metric(pred,rows,boxes):
    total=dict(positive=0,negative=0,class_correct=0,joint_correct=0,false_accepts=0,localized=0)
    domains={}
    for p,r,b in zip(pred,rows,boxes):
        own=domains.setdefault(r['domain'],dict(positive=0,negative=0,class_correct=0,joint_correct=0,false_accepts=0,localized=0))
        for target in (own,total):
            if r['label']:
                iou=normalized_iou(b,r['truth_roi']) if b is not None else 0
                target['positive']+=1;target['class_correct']+=int(p==r['label']);target['localized']+=int(iou>=.5)
                target['joint_correct']+=int(p==r['label'] and iou>=.5)
            else:target['negative']+=1;target['false_accepts']+=int(p!=0)
    return dict(total=total,domains=domains)

class FeatureModel(nn.Module):
    def __init__(self,backbone):
        super().__init__();self.backbone=backbone;self.head=nn.Linear(2048,3)
    def features(self,x):return F.layer_norm(self.backbone.features(x),(2048,))
    def forward(self,x):return self.head(self.features(x))

def models():
    torch.set_num_threads(2)
    ref,backbone,parity=load_reference(MODEL_DIR)
    teacher=FeatureModel(backbone);teacher.load_state_dict(torch.load(CHECKPOINT,map_location='cpu',weights_only=True));teacher.eval().requires_grad_(False)
    pipeline=read(LAB/'checkpoints/crop_features_preserved_20261017/PIPELINE_MANIFEST.json')
    for k in ('detector','detector_initialization','detector_reference'):assert sha(LAB/pipeline[k]['path'])==pipeline[k]['sha256']
    detector=TailDetector(MODEL_DIR,LAB/pipeline['detector_initialization']['path']).load_trainable(LAB/pipeline['detector']['path']).eval().requires_grad_(False)
    return ref,teacher,detector,parity

def locate(ref,detector,rgb):
    image,_=detector_view(rgb,'letterbox',ref)
    with torch.inference_mode():c,l=detector(torch.from_numpy(ref.tensor(image,(320,240))))
    return box_from_heads(c[0],l[0],detector.priors)

def teacher_outputs(teacher,images):
    values=[]
    with torch.inference_mode():
        for start in range(0,len(images),16):values.extend(teacher(teacher_tensor(images[start:start+16])).numpy())
    return np.stack(values)

def state_hash(m):
    h=hashlib.sha256()
    for n,v in m.state_dict().items():h.update(n.encode());h.update(v.detach().contiguous().numpy().tobytes())
    return h.hexdigest()
