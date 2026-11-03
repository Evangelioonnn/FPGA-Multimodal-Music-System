"""Hash-pinned RFB feature-tail adaptation, offline development only.

Rebuilds only Conv/Relu/Add/Concat from the local verified ONNX graph. No
downloaded Python is executed. Fused normalization coefficients are trained as
convolution parameters; there are no batch-normalization running statistics.
"""
import argparse, copy, json, math, shutil, time
from pathlib import Path
import numpy as np
from PIL import Image
import torch
from torch import nn
from gesture_detector_adaptation import (LAB, read, sha, reference_parts,
    best_detection, match, multibox_loss)
from gesture_session_detector import (to_letterbox, location_metrics,
    location_rank, train_indices, validate)
from gesture_context_adaptation import detector_view, recover_box
from gesture_spatial_quality import valid_box
from pretrained_reference import Reference, center_rgb, verify
from provenance import source_fingerprint

CUT = '/predictor/net/base_net.6/base_net.6.5/Relu_output_0'
PROTOCOL = dict(seed=20261020, epochs=24, batch_size=16, head_lr=.0001,
    backbone_lr=.00001, weight_decay=.0001, warmup_epochs=2, eval_every=2,
    private_repeat=3, input='RGB565 central square -> letterbox320x240',
    arms=['head_only', 'feature_tail'], frozen_early_blocks='base_net0..6',
    tunable_features='RFB7,base8..12,extras; fused Conv/BN coefficients',
    detector_threshold=.3, class_gate=.85, class_margin=.5,
    selection='old239 safety/min/mean localization; strict improvement; epoch0 fallback',
    ex_used_for_selection=False, test_evaluated=False, fpga_deployed=False,
    reference='Linzaer Ultra-Light RFB architecture;TorchVision partial freezing;independent graph reconstruction')


class ConvGraph(nn.Module):
    """A closed operator set for this model, retaining original graph topology."""
    def __init__(self, graph):
        super().__init__()
        from onnx import numpy_helper, helper
        arrays = {a.name: numpy_helper.to_array(a) for a in graph.initializer}
        self.input_name = graph.input[0].name
        self.output_names = [v.name for v in graph.output]
        self.layers = nn.ModuleList()
        self.instructions = []
        for node in graph.node:
            attr = {a.name: helper.get_attribute_value(a) for a in node.attribute}
            if node.op_type == 'Conv':
                weight = np.array(arrays[node.input[1]], copy=True)
                pads = attr.get('pads', [0, 0, 0, 0])
                if pads[:2] != pads[2:] or attr.get('auto_pad', b'NOTSET') != b'NOTSET':
                    raise ValueError('unsupported convolution padding')
                group = attr.get('group', 1)
                layer = nn.Conv2d(weight.shape[1] * group, weight.shape[0], weight.shape[2:],
                    stride=attr.get('strides', [1, 1]), padding=pads[:2],
                    dilation=attr.get('dilations', [1, 1]), groups=group,
                    bias=len(node.input) > 2)
                with torch.no_grad():
                    layer.weight.copy_(torch.from_numpy(weight))
                    if layer.bias is not None:
                        layer.bias.copy_(torch.from_numpy(np.array(arrays[node.input[2]], copy=True)))
                index = len(self.layers)
                self.layers.append(layer)
                self.instructions.append(('Conv', [node.input[0]], node.output[0], index))
            elif node.op_type in ('Relu', 'Add', 'Concat'):
                self.instructions.append((node.op_type, list(node.input), node.output[0], attr.get('axis', 1)))
            else:
                raise ValueError('unsupported feature operator: ' + node.op_type)

    def forward(self, x):
        values = {self.input_name: x}
        for op, inputs, output, parameter in self.instructions:
            if op == 'Conv':
                y = self.layers[parameter](values[inputs[0]])
            elif op == 'Relu':
                y = torch.relu(values[inputs[0]])
            elif op == 'Add':
                y = values[inputs[0]] + values[inputs[1]]
            else:
                y = torch.cat([values[k] for k in inputs], dim=parameter)
            values[output] = y
        return [values[k] for k in self.output_names]


class TailDetector(nn.Module):
    def __init__(self, models, initial_heads):
        super().__init__()
        import onnx
        from gesture_feature_adaptation import restore_state
        verify(models)
        model = onnx.load(str(models / 'models/hand_detector.onnx'), load_external_data=False)
        outputs = [next(n.input[0] for n in model.graph.node if n.op_type == 'Conv' and n.name.startswith(f'/predictor/net/classification_headers.{level}/')) for level in range(4)]
        extract = onnx.utils.Extractor(model)
        self.early = ConvGraph(extract.extract_model(['input'], [CUT]).graph).eval().requires_grad_(False)
        self.tail = ConvGraph(extract.extract_model([CUT], outputs).graph)
        self.heads, _, priors, _ = reference_parts(models)
        restore_state(self.heads, initial_heads)
        self.register_buffer('priors', torch.from_numpy(priors))

    def late(self, features):
        return self.heads(self.tail(features))

    def forward(self, x):
        return self.late(self.early(x)[0])

    def trainable_state(self):
        return {k: v.detach().cpu().numpy().copy() for k, v in self.state_dict().items() if k.startswith(('tail.', 'heads.'))}

    def load_trainable(self, path):
        own = self.state_dict()
        with np.load(path, allow_pickle=False) as arrays:
            required = {k for k in own if k.startswith(('tail.', 'heads.'))}
            if set(arrays.files) != required:
                raise ValueError('incomplete detector state')
            for k in required:
                if arrays[k].shape != tuple(own[k].shape) or not np.isfinite(arrays[k]).all():
                    raise ValueError('invalid detector state')
                own[k] = torch.from_numpy(arrays[k].copy())
        self.load_state_dict(own, strict=True)
        return self.eval()


def partitions(rows):
    ids = train_indices(rows, 'add_s05')
    val = [i for i, r in enumerate(rows) if r['split'] == 'val' and not r['new_session']]
    ex = [i for i, r in enumerate(rows) if r['split'] == 'val' and r['new_session']]
    if len(val) != 239 or len(ex) != 20 or set(ids) & set(val + ex):
        raise ValueError('unexpected development isolation')
    return ids, val, ex


def box_from_heads(classes, locations, priors):
    p = best_detection(classes, locations, priors, .3)
    box = recover_box(p['box'], (.75, .125, False))
    return (box if valid_box(box) else None), p['score']


@torch.no_grad()
def predict(model, features, ids, total):
    boxes, scores = [None] * total, [0.] * total
    for start in range(0, len(ids), 16):
        own = ids[start:start + 16]
        classes, locations = model.late(features[own])
        for i, c, l in zip(own, classes, locations):
            boxes[i], scores[i] = box_from_heads(c, l, model.priors)
    return boxes, scores


def cache(detector_cache, out):
    if out.exists() or out.with_suffix('.json').exists():
        raise ValueError('new output required')
    torch.set_num_threads(2)
    info = validate(detector_cache)
    sources = source_fingerprint(LAB)
    models = Path(info['models'])
    initial = LAB / 'checkpoints/s05_detector_epoch5_audit_20261017/heads.npz'
    detector = TailDetector(models, initial).eval()
    reference = Reference(models)
    _, session, _, _ = reference_parts(models)
    parity = 0.
    rng = np.random.default_rng(20261020)
    for image in (np.zeros((240, 320, 3), np.uint8), np.full((240, 320, 3), 255, np.uint8), rng.integers(0, 256, (240, 320, 3), np.uint8)):
        x = reference.tensor(image, (320, 240))
        expected = session.run(None, {'input': x})[:4]
        with torch.no_grad():
            actual = detector.tail(detector.early(torch.from_numpy(x))[0])
        for got, want in zip(actual, expected):
            np.testing.assert_allclose(got.numpy(), want, atol=2e-4, rtol=2e-4)
            parity = max(parity, float(np.abs(got.numpy() - want).max()))
    features = []
    rows = info['rows']
    partitions(rows)
    for i, row in enumerate(rows):
        with Image.open(row['path']) as im:
            image, _ = detector_view(center_rgb(im), 'letterbox', reference)
        with torch.no_grad():
            feature = detector.early(torch.from_numpy(reference.tensor(image, (320, 240))))[0]
        features.append(feature[0].numpy())
        if (i + 1) % 150 == 0:
            print(json.dumps(dict(early_cached=i + 1)), flush=True)
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(out, early=np.stack(features))
    metadata = dict(rows=rows, source_sha256=sources, cache_sha256=sha(out), models=str(models),
        initial_heads=str(initial), initial_heads_sha256=sha(initial), dataset_identities=info['dataset_identities'],
        parent_cache=str(detector_cache.resolve()), parent_cache_sha256=sha(detector_cache),
        protocol=PROTOCOL, torch_onnx_feature_max_error=parity, test_evaluated=False,
        early_shape=list(np.stack(features).shape), runtime_annotation_input=False)
    assert source_fingerprint(LAB) == sources
    out.with_suffix('.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(status='PASS',cached=len(features),parity_max_error=parity)), flush=True)


def validate_early(path):
    info = read(path.with_suffix('.json'))
    if sha(path) != info['cache_sha256'] or sha(Path(info['initial_heads'])) != info['initial_heads_sha256']:
        raise ValueError('early cache/initial head changed')
    if sha(Path(info['parent_cache'])) != info['parent_cache_sha256']:
        raise ValueError('parent cache changed')
    validate(Path(info['parent_cache']))
    if any(source_fingerprint(LAB).get(k) != v for k, v in info['source_sha256'].items()):
        raise ValueError('cache source changed')
    return info


def train(cache_path, out, arm):
    if out.exists() or arm not in PROTOCOL['arms']:
        raise ValueError('new experiment/known arm required')
    torch.set_num_threads(2)
    torch.manual_seed(PROTOCOL['seed'])
    info = validate_early(cache_path)
    sources = source_fingerprint(LAB)
    rows = info['rows']
    ids, val, ex = partitions(rows)
    model = TailDetector(Path(info['models']), Path(info['initial_heads'])).eval()
    with np.load(cache_path, allow_pickle=False) as arrays:
        early = torch.from_numpy(arrays['early'].copy())
    # These are training targets only. Validation/ex remain outside optimizer ids.
    labels, truth = [], []
    for r in rows:
        a, b = match(model.priors, to_letterbox(r['detector_box']))
        labels.append(a)
        truth.append(b)
    labels, truth = torch.stack(labels), torch.stack(truth)
    schedule = np.array([i for i in ids for _ in range(3 if rows[i]['origin'] == 'private' else 1)])
    opt = torch.optim.AdamW([dict(params=model.heads.parameters(), lr=.0001),
        dict(params=model.tail.parameters(), lr=.00001)], weight_decay=.0001)
    initial_boxes, _ = predict(model, early, val, len(rows))
    baseline = location_metrics(rows, initial_boxes, val)
    best_rank = location_rank(baseline, baseline)
    best, best_epoch = copy.deepcopy(model.state_dict()), 0
    out.mkdir(parents=True)
    for rel in sources:
        p = out / 'source' / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(LAB / rel, p)
    frozen = dict(protocol=PROTOCOL,arm=arm,source_sha256=sources,cache_sha256=sha(cache_path),
                  initial_heads_sha256=info['initial_heads_sha256'])
    (out / 'FROZEN_PROTOCOL.json').write_text(json.dumps(frozen,indent=2)+'\n',encoding='utf-8')
    rng = np.random.default_rng(PROTOCOL['seed'])
    history = []
    start = time.monotonic()
    for epoch in range(PROTOCOL['epochs']):
        model.train()
        update = arm == 'feature_tail' and epoch >= PROTOCOL['warmup_epochs']
        model.tail.requires_grad_(update)
        losses = []
        for own in np.array_split(rng.permutation(schedule), math.ceil(len(schedule) / 16)):
            opt.zero_grad()
            c, l = model.late(early[own])
            loss = multibox_loss(c, l, labels[own], truth[own])
            loss.backward()
            nn.utils.clip_grad_norm_([p for p in model.parameters() if p.requires_grad], 5)
            opt.step()
            losses.append(float(loss.detach()))
        if (epoch + 1) % 2 == 0:
            model.eval()
            boxes, _ = predict(model, early, val, len(rows))
            groups = location_metrics(rows, boxes, val)
            rank = location_rank(groups, baseline)
            if rank > best_rank:
                best_rank, best, best_epoch = rank, copy.deepcopy(model.state_dict()), epoch + 1
            entry = dict(epoch=epoch+1,loss=float(np.mean(losses)),groups=groups,rank=list(rank),best_epoch=best_epoch)
            history.append(entry)
            print(json.dumps(dict(arm=arm,**entry)),flush=True)
    model.load_state_dict(best)
    model.eval()
    boxes, scores = predict(model, early, list(range(len(rows))), len(rows))
    np.savez(out/'detector.npz', **model.trainable_state())
    newtrain = [i for i,r in enumerate(rows) if r['split']=='train' and r['new_session']]
    report = dict(status='OFFLINE_RFB_FEATURE_TAIL_ADAPTATION',arm=arm,protocol=PROTOCOL,source_sha256=sources,
        cache_path=str(cache_path.resolve()),cache_sha256=sha(cache_path),model_sha256=sha(out/'detector.npz'),
        initial_heads_sha256=info['initial_heads_sha256'],selected_epoch=best_epoch,rank=list(best_rank),
        training_images=len(ids),training_draws_per_epoch=len(schedule),baseline_old239=baseline,
        old239=location_metrics(rows,boxes,val),ex20=location_metrics(rows,boxes,ex),
        s05_training_diagnostic=location_metrics(rows,boxes,newtrain),history=history,
        predictions=[dict(r,predicted_box=b,detector_score=s) for r,b,s in zip(rows,boxes,scores)],
        elapsed_seconds=time.monotonic()-start,parameters=dict(early=sum(p.numel() for p in model.early.parameters()),
            tail=sum(p.numel() for p in model.tail.parameters()),heads=sum(p.numel() for p in model.heads.parameters())),
        ex_used_for_selection=False,test_evaluated=False,model_promoted=False,fpga_deployed=False,board_tested=False)
    assert sources == source_fingerprint(LAB)
    (out/'REPORT.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(arm=arm,selected=best_epoch,old239=report['old239'],ex=report['ex20'],s05=report['s05_training_diagnostic'])),flush=True)


if __name__ == '__main__':
    p=argparse.ArgumentParser()
    sub=p.add_subparsers(dest='command',required=True)
    c=sub.add_parser('cache');c.add_argument('--detector-cache',type=Path,required=True);c.add_argument('--out',type=Path,required=True)
    t=sub.add_parser('train');t.add_argument('--cache',type=Path,required=True);t.add_argument('--out',type=Path,required=True);t.add_argument('--arm',choices=PROTOCOL['arms'],required=True)
    a=p.parse_args()
    if a.command=='cache':cache(a.detector_cache,a.out)
    else:train(a.cache,a.out,a.arm)
