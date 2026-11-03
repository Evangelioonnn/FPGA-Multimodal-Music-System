"""RGB32 spatial student and gray64 cross-modal control, guarded original RGB teacher.

This is an offline new network with independent INT64 export validation. It
cannot be downloaded using old MY64 RTL; the full two-stage detector remains offline.
"""
import argparse
import math
import time
from stage_common import *
from student import CropStudent,kd_losses,decision
from reference import conv_int

def oracle(a,q,rgb):
    x=(a>>1).astype(np.int8) if rgb else (a>>1).reshape(64,64,1).astype(np.int8)
    for i,stride in enumerate((1 if rgb else 2,1)):x=conv_int(x,q[f'w{i}'],q[f'b{i}'],q[f'shift{i}'],stride)
    p=x.astype(np.int64).reshape(8,4,8,4,8).sum((1,3))//16
    y=q['w2'].astype(np.int64)@p.flatten()+q['b2'].astype(np.int64)
    return np.clip(y>>int(q['shift2']),-128,127).astype(np.int8)

def tensor(images,rgb):
    a=torch.from_numpy((images>>1).astype(np.float32))
    return a.permute(0,3,1,2) if rgb else a[:,None]

def main(arm):
    out=LAB/'checkpoints'/('two_stage_paired_20261022_'+arm)
    if out.exists():raise ValueError('preserve paired student')
    info=read(WORK/'RGB_DATA.json');assert sha(WORK/'RGB_DATA.npz')==info['sha256'];raw=np.load(WORK/'RGB_DATA.npz',allow_pickle=False)
    meta=read(WORK/'RGB_TRAIN_ROWS.json');rows=read(WORK/'ROWS.json');vi=[i for i,r in enumerate(rows) if r['split']=='val'];vr=[rows[i] for i in vi]
    rgb=arm.startswith('rgb');images=raw['train_rgb' if rgb else 'train_gray'];runtime=raw['rgb_runtime' if rgb else 'gray_runtime'][vi];y=raw['labels'];targets=raw['teacher_logits']
    boxes=[rows[i]['predicted_roi'] for i in vi];assert {r['group'] for r in meta}.isdisjoint(r['group'] for r in vr)
    pools={(d,c):[i for i,r in enumerate(meta) if r['domain']==d and r['label']==c] for d in ('public','phone','camera') for c in range(3)}
    torch.set_num_threads(2);torch.manual_seed(SEED);rng=np.random.default_rng(SEED);m=CropStudent()
    if rgb:
        m.convs[0]=nn.Conv2d(3,8,3,padding=1);nn.init.kaiming_normal_(m.convs[0].weight,nonlinearity='relu');nn.init.zeros_(m.convs[0].bias)
    out.mkdir();write(out/'PLAN.json',dict(arm=arm,parent_plan_sha256=sha(WORK/'RGB_PLAN.json'),cache_sha256=info['sha256'],
        steps=[6000,2000],seed=SEED,fixed_endpoints=True,legacy_MY64_compatible=False,
        inference_input='RGB32 hand crop' if rgb else 'GRAY64 hand crop',rgb_teacher_input='same physical TRAIN crop nativeRGB128',
        source_sha256={p.name:sha(p) for p in HERE.glob('*.py')}))
    start=time.monotonic();history=[];kdcount=0
    for phase,steps in [('float',6000),('qat',2000)]:
        if phase=='qat':
            probe=tensor(images[:8],rgb);m.eval();fold=m.folded()
            with torch.inference_mode():torch.testing.assert_close(m(probe),fold(probe),atol=3e-5,rtol=3e-5)
            m=fold;m.q=[min(12,max(0,int(math.floor(math.log2(127/max(float(c.weight.detach().abs().max()),1e-8)))))) for c in list(m.convs)+[m.fc]]
        lr=.0015 if phase=='float' else .00012;opt=torch.optim.AdamW(m.parameters(),lr=lr,weight_decay=.0002)
        for step in range(1,steps+1):
            m.train();ids=[int(rng.choice(pools[d,c])) for _ in range(4) for d in ('public','phone','camera') for c in range(3)]
            x=tensor(images[ids],rgb);labels=torch.from_numpy(y[ids]);pos=labels!=0;opt.zero_grad(set_to_none=True);p=m(x)
            loss=F.cross_entropy(p[:,2:],pos.long(),label_smoothing=.02)+F.cross_entropy(p[pos,:2],labels[pos]-1,label_smoothing=.02)
            if arm!='rgb32_hard':
                kd,count=kd_losses(p,torch.from_numpy(targets[ids]),labels);loss=loss+.3*kd;kdcount+=count
            assert torch.isfinite(loss);loss.backward();torch.nn.utils.clip_grad_norm_(m.parameters(),5);opt.step()
            for g in opt.param_groups:g['lr']=lr*(.15+.85*(1+math.cos(math.pi*step/steps))/2)
            if step%1000==0:
                event=dict(phase=phase,step=step,loss=float(loss.detach()),seconds=time.monotonic()-start);history.append(event);print(json.dumps(dict(arm=arm,**event)),flush=True)
        torch.save(dict(state=m.state_dict(),q=m.q,rgb=rgb),out/(phase+'_last.pt'))
    m.eval();q=m.export();np.savez(out/'quantized.npz',**q);fast=[]
    with torch.inference_mode():
        for i in range(0,len(runtime),64):fast.extend(np.clip(np.floor(m(tensor(runtime[i:i+64],rgb)).numpy()*16),-128,127).astype(np.int8))
    exact=np.stack([oracle(a,q,rgb) for a in runtime]);assert np.array_equal(exact,np.stack(fast))
    predicted=decision(exact,boxes);met=metric(predicted,vr,boxes);total=met['total'];cam=met['domains']['camera']
    eligible=total['joint_correct']>=144 and total['false_accepts']<=7 and cam['joint_correct']==8 and cam['false_accepts']==0
    write(out/'VAL.json',dict(logits_Q4=exact.tolist(),predicted=predicted.tolist(),metrics=met));write(out/'HISTORY.json',history)
    write(out/'REPORT.json',dict(status='OFFLINE_PAIRED_CROP_STUDENT_COMPARISON',arm=arm,metrics=met,eligible=eligible,parameters=sum(p.numel() for p in m.parameters()),
        exact_int64_oracle_images=len(vi),integer_exact=True,kd_eligible_draws=kdcount,quantized_sha256=sha(out/'quantized.npz'),
        elapsed_s=time.monotonic()-start,board_tested=False,original_models_unchanged=True,legacy_core_compatible=False,eval02_pixels_opened=False,live_used=False))
    print(json.dumps(dict(arm=arm,metrics=met,eligible=eligible,integer_exact=True)),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--arm',choices=['rgb32_hard','rgb32_kd','gray64_crossmodal_kd'],required=True);main(p.parse_args().arm)
