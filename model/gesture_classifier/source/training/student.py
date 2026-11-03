"""Conditional hand-crop student experiment: hard-label vs validated-teacher KL.

New 64-gray spatial classifier, NOT old MY64's weights/head interface.
Two8-channel convolutions, spatial pooling and separate posture/accept heads.
"""
import argparse
import copy
import math
import time
from stage_common import *
from reference import conv_int

TEACHER=LAB/'checkpoints/two_stage_gray_teacher_20261022'
def sr(x):return x+(x.round()-x).detach()
def sf(x):return x+(x.floor()-x).detach()

class CropStudent(nn.Module):
    def __init__(self,norms=True):
        super().__init__();self.q=None
        self.convs=nn.ModuleList([nn.Conv2d(1,8,3,stride=2,padding=1),nn.Conv2d(8,8,3,padding=1)])
        self.norms=nn.ModuleList([nn.BatchNorm2d(8,momentum=.03) if norms else nn.Identity() for _ in range(2)])
        self.fc=nn.Linear(512,4)
        for c in list(self.convs)+[self.fc]:nn.init.kaiming_normal_(c.weight,nonlinearity='relu' if c is not self.fc else 'linear');nn.init.zeros_(c.bias)
        if norms:
            for n in self.norms:nn.init.constant_(n.weight,.4)
    def forward(self,a):
        if self.q is None:
            x=a/128
            for c,n in zip(self.convs,self.norms):x=n(c(x)).clamp(0,127/128)
            x=F.avg_pool2d(x,4).permute(0,2,3,1).flatten(1)
            return self.fc(x)
        x=a
        for i,c in enumerate(self.convs):
            scale=2**self.q[i];w=sr(c.weight*scale).clamp(-128,127);b=sr(c.bias*128*scale)
            x=sf(F.conv2d(x,w,b,c.stride,c.padding)/scale).clamp(0,127)
        x=sf(F.avg_pool2d(x,4)).permute(0,2,3,1).flatten(1)
        scale=2**self.q[2];w=sr(self.fc.weight*scale).clamp(-128,127);b=sr(self.fc.bias*128*scale)
        return sf(F.linear(x,w,b)/(scale*8)).clamp(-128,127)/16
    def folded(self):
        self.eval();m=CropStudent(False)
        for i in range(2):m.convs[i]=torch.nn.utils.fusion.fuse_conv_bn_eval(self.convs[i],self.norms[i])
        m.fc=copy.deepcopy(self.fc);return m.eval()
    def export(self):
        out={}
        for i,c in enumerate(list(self.convs)+[self.fc]):
            scale=2**self.q[i];w=np.clip(np.round(c.weight.detach().numpy()*scale),-128,127).astype(np.int8)
            b=np.round(c.bias.detach().numpy()*128*scale).astype(np.int64)
            bound=127*np.abs(w.astype(np.int64)).reshape(len(w),-1).sum(1)+np.abs(b)
            assert bound.max()<2**24 and (np.abs(b)<2**31).all()
            out[f'w{i}']=w;out[f'b{i}']=b.astype(np.int32);out[f'shift{i}']=np.int64(self.q[i]+(3 if i==2 else 0))
        return out

def oracle(a,q):
    x=(a>>1).reshape(64,64,1).astype(np.int8)
    for i,stride in enumerate((2,1)):x=conv_int(x,q[f'w{i}'],q[f'b{i}'],q[f'shift{i}'],stride)
    pooled=x.astype(np.int64).reshape(8,4,8,4,8).sum((1,3))//16
    y=q['w2'].astype(np.int64)@pooled.flatten()+q['b2'].astype(np.int64)
    return np.clip(y>>int(q['shift2']),-128,127).astype(np.int8)

def decision(q4,boxes):
    v=np.asarray(q4,dtype=np.int32);pose=v[:,:2].argmax(1)+1
    stable=np.abs(v[:,0]-v[:,1])>=8;accepted=v[:,3]-v[:,2]>=8
    return np.where(stable&accepted&np.array([b is not None for b in boxes]),pose,0)

def kd_losses(s,t,y):
    temperature=2.;correct=t.argmax(1).eq(y)&((t.topk(2,1).values[:,0]-t.topk(2,1).values[:,1])>=.5)
    if not correct.any():return s.sum()*0,0
    prob=F.softmax(t[correct]/temperature,dim=1).detach();binary=torch.stack((prob[:,0],prob[:,1:].sum(1)),1)
    value=F.kl_div(F.log_softmax(s[correct,2:]/temperature,dim=1),binary,reduction='batchmean')*temperature**2
    pos=correct&y.ne(0)
    if pos.any():value=value+F.kl_div(F.log_softmax(s[pos,:2]/temperature,dim=1),F.softmax(t[pos,1:]/temperature,dim=1).detach(),reduction='batchmean')*temperature**2
    return value,int(correct.sum())

def ev(m,images,rows,boxes):
    m.eval();q4=[]
    with torch.inference_mode():
        for i in range(0,len(images),64):q4.extend(np.clip(np.floor(m(torch.from_numpy((images[i:i+64]>>1).astype(np.float32))[:,None]).numpy()*16),-128,127).astype(np.int8))
    q4=np.stack(q4);return q4,metric(decision(q4,boxes),rows,boxes)

def main(arm):
    report=read(TEACHER/'REPORT.json')
    if not report['selected']:
        print('SKIP: no eligible gray teacher; no unqualified teacher targets are distilled',flush=True);return
    out=LAB/'checkpoints'/('two_stage_crop_student_20261022_'+arm)
    if out.exists():raise ValueError('preserve experiment')
    out.mkdir();meta=read(TEACHER/'DISTILLATION_TRAIN.json');assert sha(TEACHER/'DISTILLATION_TRAIN.npz')==meta['sha256']
    data=np.load(TEACHER/'DISTILLATION_TRAIN.npz',allow_pickle=False);images=data['images'];labels=data['labels'];target=data['teacher_logits'];trainrows=meta['rows']
    rows=read(WORK/'ROWS.json');vi=[i for i,r in enumerate(rows) if r['split']=='val'];vr=[rows[i] for i in vi]
    assert {r['group'] for r in trainrows}.isdisjoint(r['group'] for r in vr)
    runtime=np.load(WORK/'DATA.npz',allow_pickle=False)['student_runtime'][vi]
    boxes=read(WORK/'AUTOMATIC_BOXES.json')['boxes']['gray_native_auto64_up128'];vb=[boxes[i] for i in vi]
    pools={(d,c):[i for i,r in enumerate(trainrows) if r['domain']==d and r['label']==c] for d in ('public','phone','camera') for c in range(3)}
    plan=dict(arm=arm,teacher_sha256=meta['teacher_sha256'],data_sha256=meta['sha256'],seed=SEED,
        steps=[6000,2000],input='automatic hand crop64 GRAY8,gray>>1 unsignedQ7',
        architecture='Conv1to8s2,Conv8to8s1,AvgPool4x4,spatial512to4;separate2posture+2accept logits',
        decoder='posturegap>=8Q4 ANDaccept_minus_reject>=8Q4 ANDlocator_present',
        loss='positive-only postureCE + all-image binary acceptanceCE;KD arm+.3*temperature2KL onlyteacher-correct-and-margin>=.5',
        selection='fixed last endpoints;historicalVAL comparison after both stages,not current3/eval02',
        legacy_MY64_compatible=False,fpga_resources_unmeasured=True,source_sha256={p.name:sha(p) for p in HERE.glob('*.py')})
    write(out/'PLAN.json',plan);torch.set_num_threads(2);torch.manual_seed(SEED);rng=np.random.default_rng(SEED);m=CropStudent();history=[];start=time.monotonic();kdcount=0
    for phase,steps in [('float',6000),('qat',2000)]:
        if phase=='qat':
            probe=torch.from_numpy((images[:8]>>1).astype(np.float32))[:,None];m.eval();fold=m.folded()
            with torch.inference_mode():torch.testing.assert_close(m(probe),fold(probe),atol=3e-5,rtol=3e-5)
            m=fold;m.q=[min(12,max(0,int(math.floor(math.log2(127/max(float(c.weight.detach().abs().max()),1e-8)))))) for c in list(m.convs)+[m.fc]]
        lr=.0015 if phase=='float' else .00012;opt=torch.optim.AdamW(m.parameters(),lr=lr,weight_decay=.0002)
        for step in range(1,steps+1):
            m.train();ids=[int(rng.choice(pools[d,c])) for _ in range(4) for d in ('public','phone','camera') for c in range(3)]
            x=torch.from_numpy((images[ids]>>1).astype(np.float32))[:,None];y=torch.from_numpy(labels[ids]);positive=y!=0
            opt.zero_grad(set_to_none=True);p=m(x);loss=F.cross_entropy(p[:,2:],positive.long(),label_smoothing=.02)+F.cross_entropy(p[positive,:2],y[positive]-1,label_smoothing=.02)
            if arm=='kd':
                value,count=kd_losses(p,torch.from_numpy(target[ids]),y);loss=loss+.3*value;kdcount+=count
            assert torch.isfinite(loss);loss.backward();torch.nn.utils.clip_grad_norm_(m.parameters(),5);opt.step()
            for g in opt.param_groups:g['lr']=lr*(.15+.85*(1+math.cos(math.pi*step/steps))/2)
            if step%1000==0:
                event=dict(phase=phase,step=step,loss=float(loss.detach()),elapsed_s=time.monotonic()-start);history.append(event);print(json.dumps(dict(arm=arm,**event)),flush=True)
        torch.save(dict(state=m.state_dict(),q=m.q),out/(phase+'_last.pt'))
    m.eval();q=m.export();np.savez(out/'quantized.npz',**q)
    fast,met=ev(m,runtime,vr,vb);exact=np.stack([oracle(a,q) for a in runtime]);assert np.array_equal(exact,fast)
    ref=metric(decision(exact,vb),vr,vb);assert ref==met
    write(out/'VAL.json',dict(logits_Q4=exact.tolist(),predicted=decision(exact,vb).tolist(),metrics=met))
    write(out/'HISTORY.json',history)
    write(out/'REPORT.json',dict(status='OFFLINE_CROP_STUDENT_INT8_COMPARISON',arm=arm,metrics=met,parameters=sum(p.numel() for p in m.parameters()),
        exact_int64_oracle_images=len(vi),integer_exact=True,kd_eligible_draws=kdcount,quantized_sha256=sha(out/'quantized.npz'),
        elapsed_s=time.monotonic()-start,board_tested=False,original_models_unchanged=True,legacy_core_compatible=False,eval02_pixels_opened=False,live_used=False))
    print(json.dumps(dict(arm=arm,metrics=met,integer_exact=True,seconds=time.monotonic()-start)),flush=True)

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--arm',choices=['hard','kd'],required=True);main(ap.parse_args().arm)
