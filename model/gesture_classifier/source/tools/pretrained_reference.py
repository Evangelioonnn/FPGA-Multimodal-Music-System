"""Pinned official HaGRID-author ONNX benchmark, OFFLINE REFERENCE ONLY.

No downloaded Python is executed. The 45-class reference is not MY64 firmware.
HaGRID-subset results may overlap upstream pretraining and are diagnostics,
not independent generalization or FPGA feasibility evidence.
"""
import argparse
import ast
from collections import Counter
import datetime
import hashlib
import json
from pathlib import Path
import time
import urllib.request

import numpy as np
from PIL import Image
from dataset import load_records,fingerprint
from reference import rgb565_rgb

COMMIT='557a836bf82fce8d36494d0c17e95ca236f5611c'
REPOSITORY='https://github.com/ai-forever/dynamic_gestures'
BASE=f'https://raw.githubusercontent.com/ai-forever/dynamic_gestures/{COMMIT}/'
FILES={
 'models/hand_detector.onnx':'a8ef73d466b61a8e8677be9c47008b217a11d1b265d95e36bf2521ff93329af6',
 'models/crops_classifier.onnx':'12a02344f63a7c4f2a2ca90f8740ca10a08c17b683b5585d73c3e88323056762',
 'license/LICENSE-2.0.txt':'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30',
 'onnx_models.py':'b8784b23d2ca9914b3ce5aa174162308e2d66f8d5e522cbad19a790b637b2bb4',
 'utils/enums.py':'6810832332314209742bf492de03eba00d8c3c4ebfa3b0af538b429a1b0e7814'}


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def fetch(out):
    if out.exists():raise ValueError('use a new reference download directory')
    out.mkdir(parents=True);records=[]
    for name,digest in FILES.items():
        with urllib.request.urlopen(BASE+name,timeout=40) as response:raw=response.read(4*1024*1024+1)
        if len(raw)>4*1024*1024 or hashlib.sha256(raw).hexdigest()!=digest:raise ValueError('reference content mismatch: '+name)
        path=out/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(raw)
        records.append(dict(file=name,url=BASE+name,bytes=len(raw),sha256=digest))
    info=dict(repository=REPOSITORY,commit=COMMIT,files=records,time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        usage='OFFLINE_REFERENCE_ONLY',downloaded_python_executed=False,private_images_uploaded=False)
    (out/'SOURCE.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(commit=COMMIT,files=len(records),bytes=sum(r['bytes'] for r in records)),indent=2))


def verify(folder):
    for name,digest in FILES.items():
        if sha(folder/name)!=digest:raise ValueError('modified reference: '+name)


def labels_from_source(text):
    tree=ast.parse(text)
    for node in tree.body:
        if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='targets' for t in node.targets):
            labels=ast.literal_eval(node.value)
            if len(labels)!=45 or labels[25]!='fist' or labels[31]!='palm':raise ValueError('unexpected reference mapping')
            return labels
    raise ValueError('missing labels')


def center_rgb(im):
    w,h=im.size;side=min(w,h);left,top=(w-side)//2,(h-side)//2
    rgb=np.asarray(im.convert('RGB'),dtype=np.uint16)
    packed=((rgb[:,:,0]>>3)<<11)|((rgb[:,:,1]>>2)<<5)|(rgb[:,:,2]>>3)
    return rgb565_rgb(packed)[top:top+side,left:left+side].copy()


def gray_view(rgb,size):
    height,width=rgb.shape[:2]
    yy=np.arange(size)*height//size;xx=np.arange(size)*width//size
    sample=rgb[yy[:,None],xx[None,:]].astype(np.uint16)
    gray=((77*sample[:,:,0]+150*sample[:,:,1]+29*sample[:,:,2])>>8).astype(np.uint8)
    return np.repeat(gray[:,:,None],3,axis=2)


def roi_box(box,size):
    w,h=size;side=min(size);left,top=(w-side)//2,(h-side)//2
    x,y,bw,bh=box
    return [(x*w-left)/side,(y*h-top)/side,bw*w/side,bh*h/side]


def square_pixels(box,size):
    """Match upstream square expansion and integer clipping to width-1."""
    width,height=size;x0,y0,x1,y1=map(int,box);w,h=x1-x0,y1-y0
    if h<w:y0-=int((w-h)/2);y1=y0+w
    if h>w:x0-=int((h-w)/2);x1=x0+h
    x0,y0=max(0,x0),max(0,y0);x1,y1=min(width-1,x1),min(height-1,y1)
    if x1<=x0 or y1<=y0:raise ValueError('empty hand crop')
    return x0,y0,x1,y1


def box_corners(box,size):
    x,y,w,h=box;return [(x-w/2)*size,(y-h/2)*size,(x+w/2)*size,(y+h/2)*size]


def normalized_iou(a,b):
    a=np.array(box_corners(a,1));b=np.array(box_corners(b,1))
    intersection=np.maximum(np.minimum(a[2:],b[2:])-np.maximum(a[:2],b[:2]),0).prod()
    union=(a[2:]-a[:2]).prod()+(b[2:]-b[:2]).prod()-intersection
    return float(intersection/union) if union>0 else 0.


class Reference:
    def __init__(self,folder):
        verify(folder)
        import cv2
        import onnx
        import onnxruntime as ort
        self.cv2=cv2;self.labels=labels_from_source((folder/'utils/enums.py').read_text(encoding='utf-8'))
        self.sessions={};self.graphs={}
        for name in ('hand_detector','crops_classifier'):
            path=folder/f'models/{name}.onnx';model=onnx.load(str(path),load_external_data=False)
            if any(t.data_location==onnx.TensorProto.EXTERNAL for t in model.graph.initializer):raise ValueError('external model tensor not allowed')
            if any(n.domain not in ('','ai.onnx') for n in model.graph.node):raise ValueError('unexpected custom operator')
            onnx.checker.check_model(model)
            options=ort.SessionOptions();options.intra_op_num_threads=2;options.inter_op_num_threads=1
            self.sessions[name]=ort.InferenceSession(str(path),sess_options=options,providers=['CPUExecutionProvider'])
            self.graphs[name]=dict(parameters=sum(int(np.prod(t.dims)) for t in model.graph.initializer),
                initializer_bytes=sum(len(t.raw_data) for t in model.graph.initializer),
                operators=dict(Counter(n.op_type for n in model.graph.node)),file_sha256=sha(path))

    def tensor(self,rgb,shape):
        image=self.cv2.resize(rgb,shape,interpolation=self.cv2.INTER_LINEAR)
        return np.ascontiguousarray(((image.astype(np.float32)-127)/128).transpose(2,0,1)[None])

    def classify(self,crop):
        session=self.sessions['crops_classifier']
        logits=session.run(None,{session.get_inputs()[0].name:self.tensor(crop,(128,128))})[0][0]
        label=self.labels[int(logits.argmax())]
        return dict(label=label,class_id={'palm':1,'fist':2}.get(label,0),logits=logits.tolist())

    def predict(self,rgb):
        session=self.sessions['hand_detector']
        boxes,_,scores=session.run(None,{session.get_inputs()[0].name:self.tensor(rgb,(320,240))})
        if not len(scores):return dict(class_id=0,present=False,confidence=0,box=None)
        index=int(np.argmax(scores));score=float(scores[index])
        if score<.5:return dict(class_id=0,present=False,confidence=score,box=None)
        h,w=rgb.shape[:2];pixels=(boxes[index]*[w,h,w,h]).astype(np.int32)
        try:x0,y0,x1,y1=square_pixels(pixels,(w,h))
        except ValueError:return dict(class_id=0,present=False,confidence=score,box=None)
        classification=self.classify(rgb[y0:y1,x0:x1]);x0,y0,x1,y1=pixels/[w,h,w,h]
        box=[float((x0+x1)/2),float((y0+y1)/2),float(x1-x0),float(y1-y0)]
        return dict(class_id=classification['class_id'],label=classification['label'],present=classification['class_id']!=0,confidence=score,box=box)

    def oracle(self,rgb,box,gray_size=None,rgb_size=None):
        x0,y0,x1,y1=square_pixels(box_corners(box,rgb.shape[0]),(rgb.shape[1],rgb.shape[0]))
        crop=rgb[y0:y1,x0:x1]
        if gray_size:crop=gray_view(crop,gray_size)
        if rgb_size:crop=self.cv2.resize(crop,(rgb_size,rgb_size),interpolation=self.cv2.INTER_LINEAR)
        return self.classify(crop)


def summarize(items,pred_key):
    positive=[i for i in items if i['expected_class']];negative=[i for i in items if not i['expected_class']]
    return dict(images=len(items),positive=len(positive),negative=len(negative),
        class_correct=sum(i[pred_key]['class_id']==i['expected_class'] for i in positive),
        joint_correct=sum(i[pred_key]['class_id']==i['expected_class'] and i[pred_key]['box'] is not None and normalized_iou(i[pred_key]['box'],i['expected_box'])>=.5 for i in positive),
        false_positive=sum(i[pred_key]['present'] for i in negative))


def benchmark(folder,manifest,out,split='val'):
    if out.exists():raise ValueError('use a new report filename')
    rows=[r for r in load_records(manifest) if r['split']==split]
    if split=='test':raise ValueError('development reference does not evaluate test')
    before=fingerprint(manifest,rows);reference=Reference(folder);items=[];start=time.monotonic()
    for row in rows:
        with Image.open(manifest.parent/row['image']) as im:
            rgb=center_rgb(im);size=im.size
        expected={'open':1,'fist':2}.get(row['boxes'][0]['class'],0) if row['boxes'] else 0
        box=roi_box(row['boxes'][0]['xywh'],size) if row['boxes'] else None
        rec=dict(image=row['image'],group=row['group'],expected_class=expected,expected_box=box,negative_kind=row.get('negative_kind'),
            native=reference.predict(rgb),native_gray=reference.predict(gray_view(rgb,rgb.shape[0])),gray64=reference.predict(gray_view(rgb,64)))
        if box:
            rec['oracle_native']=reference.oracle(rgb,box)
            # Crop AFTER whole-image decimation: detail was already discarded.
            rec['oracle_gray64_after']=reference.oracle(gray_view(rgb,64),box)
            rec['oracle_gray32_before']=reference.oracle(rgb,box,32)
            rec['oracle_gray64_before']=reference.oracle(rgb,box,64)
            rec['oracle_rgb32_before']=reference.oracle(rgb,box,rgb_size=32)
        items.append(rec)
    summary={k:summarize(items,k) for k in ('native','native_gray','gray64')}
    positive=[i for i in items if i['expected_class']]
    for key in ('oracle_native','oracle_gray64_after','oracle_gray32_before','oracle_gray64_before','oracle_rgb32_before'):
        summary[key]=dict(images=len(positive),class_correct=sum(i[key]['class_id']==i['expected_class'] for i in positive),
            localization_supplied_by_ground_truth=True,end_to_end=False)
    if before!=fingerprint(manifest,rows):raise ValueError('data changed during benchmark')
    report=dict(status='OFFLINE_REFERENCE_DIAGNOSIS_NOT_FPGA_ACCEPTANCE',repository=REPOSITORY,commit=COMMIT,
        time=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),manifest=str(manifest),
        split=split,source_dataset_sha256=before['sha256'],all_labels_reviewed=all(r['label_status']=='reviewed' for r in rows),
        pretrained_hagrid_overlap_possible=any('hagrid' in r.get('source','').lower() for r in rows),
        detector_threshold=.5,classifier_threshold='upstream argmax; only palm/fist accepted',
        graphs=reference.graphs,elapsed_seconds=time.monotonic()-start,summary=summary,items=items,
        fpga_deployed=False,board_tested=False,test_evaluated=False,approved_for_gesture_use=False)
    out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(status=report['status'],overlap_possible=report['pretrained_hagrid_overlap_possible'],summary=summary,seconds=report['elapsed_seconds']),indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser();sub=p.add_subparsers(dest='command',required=True)
    f=sub.add_parser('fetch');f.add_argument('--out',type=Path,required=True)
    b=sub.add_parser('benchmark');b.add_argument('--models',type=Path,required=True);b.add_argument('--manifest',type=Path,required=True);b.add_argument('--out',type=Path,required=True)
    a=p.parse_args()
    if a.command=='fetch':fetch(a.out)
    else:benchmark(a.models,a.manifest,a.out)
