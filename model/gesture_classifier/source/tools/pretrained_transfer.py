"""Offline pretrained-feature transfer, not a Gowin/YOLO firmware export.

Uses only the five hash-pinned HaGRID-author reference files. Matches their
canonical RGB128 crop and ONNX logits before extracting frozen features.
Only reviewed public/private TRAIN labels optimize the project heads. Private
VAL is historical development diagnosis, never a fresh certification test.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import random
import shutil
import time

import numpy as np
from PIL import Image
import torch
from torch import nn
from torch.nn import functional as F

from dataset import fingerprint, load_records, training_partitions
from domain_adaptation import check_isolation
from pretrained_reference import Reference, center_rgb, normalized_iou, verify
from provenance import source_fingerprint
from roi_classifier import record_box

LAB = Path(__file__).resolve().parents[1]
FORMAT = 'HAGRID_RGB128_FROZEN_FEATURE_TRANSFER_V1'
PROTOCOL = dict(seed=20261016, epochs=160, lr=.003, weight_decay=.01,
                private_train_repeat=4, batch_size=32, reject_margin=.5,
                selection='public_reviewed_val_balanced_accuracy_only',
                arms=['linear', 'semantic_residual'], residual_bound=1.)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def canonical_bounds(box, size):
    """Exact upstream get_square convention, including early edge clamping."""
    width, height = size
    x0, y0, x1, y1 = map(int, box)
    w, h = x1-x0, y1-y0
    if h < w:
        y0 = max(0, y0-int((w-h)/2)); y1 = min(height-1, y0+w)
    if h > w:
        x0 = max(0, x0-int((h-w)/2)); x1 = min(width-1, x0+h)
    bounds = max(0, x0), max(0, y0), min(width-1, x1), min(height-1, y1)
    if bounds[2] <= bounds[0] or bounds[3] <= bounds[1]:
        raise ValueError('empty canonical crop')
    return bounds


def canonical_crop(rgb, box):
    if box is None:
        return rgb.copy()  # Explicit whole central ROI for true background.
    x, y, w, h = box
    side = rgb.shape[0]
    bounds = [(x-w/2)*side, (y-h/2)*side, (x+w/2)*side, (y+h/2)*side]
    x0, y0, x1, y1 = canonical_bounds(bounds, (rgb.shape[1], rgb.shape[0]))
    return rgb[y0:y1, x0:x1].copy()


def project_groups(labels):
    opened = [i for i, label in enumerate(labels) if label in ('palm', 'stop', 'stop_inverted')]
    closed = [i for i, label in enumerate(labels) if label in ('fist', 'fist_inverted')]
    if len(opened) != 3 or len(closed) != 2:
        raise ValueError('unexpected reference taxonomy')
    other = [i for i in range(len(labels)) if i not in opened+closed]
    return [other, opened, closed]


def grouped_logits(logits, groups):
    # Max preserves upstream argmax semantics without 40-class probability mass.
    return np.stack([np.asarray(logits)[:, group].max(axis=1) for group in groups], axis=1).astype(np.float32)


class CanonicalBackbone(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(3, 32, 3, padding=1)
        self.conv2 = nn.Conv2d(32, 32, 3, padding=1)
        self.skip = nn.Conv2d(3, 32, 1)
        self.classifier = nn.Linear(2048, 45)

    def features(self, value):
        value = F.relu(self.conv2(F.relu(self.conv1(value)))+self.skip(value))
        return F.avg_pool2d(value, 16).flatten(1)

    def forward(self, value):
        return self.classifier(self.features(value))

    def load_arrays(self, arrays):
        mapping = {'conv1.weight': 'onnx::Conv_31', 'conv1.bias': 'onnx::Conv_32',
                   'conv2.weight': 'onnx::Conv_34', 'conv2.bias': 'onnx::Conv_35',
                   'skip.weight': 'skip_connection.weight', 'skip.bias': 'skip_connection.bias',
                   'classifier.weight': 'classifier.2.weight', 'classifier.bias': 'classifier.2.bias'}
        state = {}
        for name, expected in self.state_dict().items():
            value = np.array(arrays[mapping[name]], dtype=np.float32, copy=True)
            if value.shape != tuple(expected.shape) or not np.isfinite(value).all():
                raise ValueError('bad pretrained tensor: '+name)
            state[name] = torch.from_numpy(value)
        self.load_state_dict(state, strict=True)
        self.eval()
        self.requires_grad_(False)


def load_reference(models):
    import onnx
    from onnx import numpy_helper
    verify(models)
    reference = Reference(models)
    graph = onnx.load(str(models / 'models/crops_classifier.onnx'), load_external_data=False)
    backbone = CanonicalBackbone()
    backbone.load_arrays({value.name: numpy_helper.to_array(value) for value in graph.graph.initializer})
    rng = np.random.default_rng(112)
    maximum = 0.
    for image in (np.zeros((128, 128, 3), np.uint8), np.full((128, 128, 3), 255, np.uint8),
                  rng.integers(0, 256, (128, 128, 3), dtype=np.uint8)):
        tensor = reference.tensor(image, (128, 128))
        expected = reference.sessions['crops_classifier'].run(None, {'input': tensor})[0]
        with torch.no_grad(): actual = backbone(torch.from_numpy(tensor)).numpy()
        np.testing.assert_allclose(actual, expected, atol=3e-4, rtol=1e-4)
        maximum = max(maximum, float(np.abs(actual-expected).max()))
    return reference, backbone, maximum


def prepare(public_manifest, private_manifest, models, out, quarter_turns=1):
    if out.exists() or out.with_suffix('.json').exists():
        raise ValueError('use a new cache filename')
    if quarter_turns not in (1,4):
        raise ValueError('quarter_turns must be 1 or 4')
    torch.set_num_threads(2)
    sources = source_fingerprint(LAB)
    datasets = []
    for origin, manifest in [('public', public_manifest), ('private', private_manifest)]:
        all_rows = load_records(manifest)
        if any(row['split'] == 'test' for row in all_rows):
            raise ValueError('development source must exclude test')
        rows = [row for row in all_rows if row['label_status'] == 'reviewed']
        training_partitions(rows, pilot=True)
        datasets.append((origin, manifest, rows, fingerprint(manifest, rows)))
    check_isolation([(manifest, rows) for _, manifest, rows, _ in datasets])
    reference, backbone, parity = load_reference(models)
    groups = project_groups(reference.labels)
    features, logits45, metadata, pending, pending_meta = [], [], [], [], []

    def flush():
        if not pending:
            return
        value = torch.from_numpy(np.concatenate(pending))
        with torch.no_grad():
            feature = backbone.features(value)
            original_logits = backbone.classifier(feature)
        features.extend(feature.numpy()); logits45.extend(original_logits.numpy())
        metadata.extend(pending_meta)
        pending.clear(); pending_meta.clear()

    for origin, manifest, rows, identity in datasets:
        for row in rows:
            with Image.open(manifest.parent / row['image']) as image:
                rgb, box = center_rgb(image), record_box(row, image.size)
            crop = canonical_crop(rgb, box)
            label = {'open': 1, 'fist': 2}[row['boxes'][0]['class']] if row['boxes'] else 0
            for rotation in (range(quarter_turns) if row['split']=='train' else [0]):
                for flipped in ([False, True] if row['split'] == 'train' else [False]):
                    view = np.rot90(crop,rotation)
                    view = view[:, ::-1].copy() if flipped else view.copy()
                    pending.append(reference.tensor(view, (128, 128)))
                    pending_meta.append(dict(origin=origin, image=row['image'], split=row['split'], group=row['group'],
                        label_status=row['label_status'], expected=label, horizontal_flip=flipped, quarter_rotation=rotation,
                        roi_supplied=box is not None, negative_kind=row.get('negative_kind')))
                    if len(pending) == 16:
                        flush()
            if len(metadata) and len(metadata) % 160 == 0:
                print(json.dumps(dict(origin=origin, cached=len(metadata))), flush=True)
        if identity != fingerprint(manifest, rows):
            raise ValueError('source changed while caching')
    flush()
    if sources != source_fingerprint(LAB):
        raise ValueError('code changed while caching')
    features, logits45 = np.stack(features), np.stack(logits45)
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(out, features=features, logits45=logits45,
                        base3=grouped_logits(logits45, groups), labels=np.array([row['expected'] for row in metadata], np.int64))
    info = dict(format=FORMAT, source_sha256=sources, rows=metadata, cache_sha256=sha(out),
        reference_commit='557a836bf82fce8d36494d0c17e95ca236f5611c', model_folder=str(models.resolve()),
        reference_onnx_sha256=sha(models / 'models/crops_classifier.onnx'), torch_onnx_max_error=parity,
        project_groups=groups, quarter_turns=quarter_turns, all_labels_reviewed=True, public_pretrained_overlap_possible=True,
        source_manifests=[dict(origin=origin, path=str(manifest.resolve()), identity=identity) for origin, manifest, _, identity in datasets],
        canonical_crop='upstream square, no context expansion; background=whole central ROI',
        tensor='RGB565 approximation; OpenCV bilinear RGB128; (RGB-127)/128', test_evaluated=False)
    out.with_suffix('.json').write_text(json.dumps(info, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(dict(cache=str(out), inputs=len(metadata), unique_sources=sum(len(rows) for _, _, rows, _ in datasets), parity_error=parity)), flush=True)


def partitions(rows):
    if any(row['split'] == 'test' or row['label_status'] != 'reviewed' for row in rows):
        raise ValueError('only reviewed development inputs allowed')
    train = np.array([i for i, row in enumerate(rows) if row['split'] == 'train'])
    public_val = np.array([i for i, row in enumerate(rows) if row['split'] == 'val' and row['origin'] == 'public'])
    private_val = np.array([i for i, row in enumerate(rows) if row['split'] == 'val' and row['origin'] == 'private'])
    if not all(len(ids) for ids in (train, public_val, private_val)):
        raise ValueError('need train, public val, and private diagnostic')
    return train, public_val, private_val


def measurements(logits, labels, margin=.5):
    values = np.asarray(logits)
    predicted = values.argmax(axis=1)
    sorted_values = np.sort(values, axis=1)
    predicted = np.where((predicted != 0) & (sorted_values[:, -1]-sorted_values[:, -2] < margin), 0, predicted)
    matrix = np.zeros((3, 3), np.int64)
    for actual, pred in zip(labels, predicted):
        matrix[int(actual), int(pred)] += 1
    return dict(images=len(labels), confusion_other_open_fist=matrix.tolist(),
        target_correct=int(matrix[1, 1]+matrix[2, 2]), target_images=int(matrix[1:].sum()),
        false_target=int(matrix[0, 1:].sum()), negative_images=int(matrix[0].sum()),
        balanced_accuracy=float(np.mean(np.diag(matrix)/np.maximum(matrix.sum(axis=1), 1))))


class ProjectHead(nn.Module):
    def __init__(self, arm):
        super().__init__()
        if arm not in PROTOCOL['arms']:
            raise ValueError('unknown head arm')
        self.arm = arm
        self.linear = nn.Linear(2048, 3)
        nn.init.zeros_(self.linear.weight); nn.init.zeros_(self.linear.bias)

    def forward(self, features, base):
        delta = self.linear(features)
        return base+PROTOCOL['residual_bound']*torch.tanh(delta) if self.arm == 'semantic_residual' else delta


def validate_cache(cache):
    info = read_json(cache.with_suffix('.json'))
    if info['format'] != FORMAT or sha(cache) != info['cache_sha256']:
        raise ValueError('cache changed or wrong format')
    verify(Path(info['model_folder']))
    for source in info['source_manifests']:
        manifest = Path(source['path'])
        rows = [row for row in load_records(manifest) if row['label_status'] == 'reviewed']
        if fingerprint(manifest, rows) != source['identity']:
            raise ValueError('data no longer matches cache')
    return info


def train(cache, out):
    if out.exists():
        raise ValueError('use a new experiment directory')
    torch.set_num_threads(2)
    sources = source_fingerprint(LAB)
    info = validate_cache(cache)
    if info['source_sha256'] != sources:
        raise ValueError('feature extraction source no longer matches training source')
    with np.load(cache, allow_pickle=False) as archive:
        features, base, labels = archive['features'], archive['base3'], archive['labels']
    rows = info['rows']
    train_ids, public_val, private_val = partitions(rows)
    if len(features) != len(rows) or not np.array_equal(labels, [row['expected'] for row in rows]):
        raise ValueError('cache labels/order mismatch')
    mean = features[train_ids].mean(axis=0)
    scale = np.maximum(features[train_ids].std(axis=0), .05)
    normalized = torch.from_numpy(((features-mean)/scale).astype(np.float32))
    base_tensor, labels_tensor = torch.from_numpy(base), torch.from_numpy(labels)
    schedule = np.array([i for i in train_ids for _ in range(PROTOCOL['private_train_repeat'] if rows[i]['origin'] == 'private' else 1)])
    counts = np.bincount(labels[schedule], minlength=3)
    if min(counts) == 0:
        raise ValueError('training needs all project classes')
    weights = torch.from_numpy((len(schedule)/(3*counts)).astype(np.float32))
    out.mkdir(parents=True)
    for relative in sources:
        destination = out / 'source' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(LAB / relative, destination)
    (out / 'FROZEN_PROTOCOL.json').write_text(json.dumps(dict(protocol=PROTOCOL, source_sha256=sources,
        cache_sha256=sha(cache), reviewed_only=True, private_val_used_for_selection=False), indent=2)+'\n', encoding='utf-8')
    experiments = {}
    frozen = {}
    for arm in PROTOCOL['arms']:
        torch.manual_seed(PROTOCOL['seed']); random.seed(PROTOCOL['seed'])
        rng = np.random.default_rng(PROTOCOL['seed'])
        head = ProjectHead(arm)
        optimizer = torch.optim.AdamW(head.parameters(), lr=PROTOCOL['lr'], weight_decay=PROTOCOL['weight_decay'])
        best, best_rank, best_epoch = None, None, None
        history, started = [], time.monotonic()
        for epoch in range(PROTOCOL['epochs']):
            rate = .05+.95*(1+math.cos(math.pi*epoch/(PROTOCOL['epochs']-1)))/2
            for group in optimizer.param_groups: group['lr'] = PROTOCOL['lr']*rate
            order = rng.permutation(schedule)
            losses = []
            for begin in range(0, len(order), PROTOCOL['batch_size']):
                ids = order[begin:begin+PROTOCOL['batch_size']]
                optimizer.zero_grad()
                output = head(normalized[ids], base_tensor[ids])
                loss = F.cross_entropy(output, labels_tensor[ids], weight=weights)
                if arm == 'semantic_residual': loss = loss+.01*(output-base_tensor[ids]).square().mean()
                loss.backward(); optimizer.step(); losses.append(float(loss.detach()))
            if epoch == 0 or (epoch+1) % 10 == 0:
                with torch.no_grad(): val_logits = head(normalized[public_val], base_tensor[public_val]).numpy()
                score = measurements(val_logits, labels[public_val], PROTOCOL['reject_margin'])
                rank = (score['balanced_accuracy'], -score['false_target'], score['target_correct'])
                entry = dict(epoch=epoch+1, training_loss=float(np.mean(losses)), public_val=score)
                history.append(entry); print(json.dumps(dict(arm=arm, **entry)), flush=True)
                if best_rank is None or rank > best_rank:
                    best_rank, best_epoch = rank, epoch+1
                    best = {key: value.detach().clone() for key, value in head.state_dict().items()}
        head.load_state_dict(best); head.eval()
        frozen[arm] = head
        # Both heads are frozen before private evaluation below.
        np.savez(out / (arm+'.npz'), weight=head.linear.weight.detach().numpy(), bias=head.linear.bias.detach().numpy(), mean=mean, scale=scale)
        experiments[arm] = dict(selected_epoch=best_epoch, elapsed_seconds=time.monotonic()-started,
                                history=history, head_sha256=sha(out / (arm+'.npz')))
    for arm, head in frozen.items():
        with torch.no_grad(): logits = head(normalized, base_tensor).numpy()
        for split, ids in [('train', train_ids), ('public_val', public_val), ('private_diagnostic', private_val)]:
            experiments[arm][split] = dict(argmax=measurements(logits[ids], labels[ids], 0),
                gated=measurements(logits[ids], labels[ids], PROTOCOL['reject_margin']))
            if split == 'private_diagnostic':
                experiments[arm]['private_items'] = [dict(rows[i], logits=logits[i].tolist()) for i in ids]
    baseline = {name: measurements(base[ids], labels[ids], 0) for name, ids in [('public_val', public_val), ('private_diagnostic', private_val)]}
    if sources != source_fingerprint(LAB) or validate_cache(cache)['cache_sha256'] != info['cache_sha256']:
        raise ValueError('source or data changed during training')
    report = dict(status='FROZEN_PRETRAINED_FEATURE_TRANSFER_EXPERIMENT_ONLY', format=FORMAT,
        source_sha256=sources, protocol=PROTOCOL, cache_sha256=sha(cache), cache_path=str(cache.resolve()),
        reference_onnx_sha256=info['reference_onnx_sha256'], canonical_tensor=info['tensor'],
        base_coarse_project_mapping=info['project_groups'], original_coarse_baseline=baseline,
        unique_public_train=sum(row['split']=='train' and row['origin']=='public' and not row['horizontal_flip'] and row.get('quarter_rotation',0)==0 for row in rows),
        unique_private_train=sum(row['split']=='train' and row['origin']=='private' and not row['horizontal_flip'] and row.get('quarter_rotation',0)==0 for row in rows),
        augmented_train_inputs=len(train_ids),
        train_draws_per_epoch=len(schedule), draft_training_images=0,
        public_pretrained_overlap_possible=True, private_is_historical_diagnostic=True,
        private_train_images_used=True, private_validation_used_for_training=False, private_val_used_for_selection=False,
        experiments=experiments, backbone_frozen=True, oracle_roi=True,
        full_frame_detector_integrated=False, fpga_rtl_implemented=False,
        synthesis=False, pnr=False, board_tested=False, approved_for_gesture_use=False)
    (out / 'REPORT.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(dict(status=report['status'], baseline=baseline,
        experiments={arm: {key: value for key, value in entry.items() if key in ('selected_epoch','public_val','private_diagnostic')}
                     for arm, entry in experiments.items()}), indent=2), flush=True)


def predict_image(rgb, reference, backbone, head, mean, scale, groups):
    """No annotation or expected class enters inference."""
    detector = reference.sessions['hand_detector']
    boxes, _, scores = detector.run(None, {detector.get_inputs()[0].name: reference.tensor(rgb, (320,240))})
    if not len(scores) or float(np.max(scores)) < .5:
        return dict(class_id=0, box=None, detection_score=float(np.max(scores)) if len(scores) else 0.)
    index = int(np.argmax(scores));height,width=rgb.shape[:2]
    raw = boxes[index]*[width,height,width,height]
    try: x0,y0,x1,y1=canonical_bounds(raw,(width,height))
    except ValueError: return dict(class_id=0,box=None,detection_score=float(scores[index]))
    tensor = torch.from_numpy(reference.tensor(rgb[y0:y1,x0:x1],(128,128)))
    with torch.no_grad():
        feature=backbone.features(tensor)
        original=backbone.classifier(feature).numpy()
        base=torch.from_numpy(grouped_logits(original,groups))
        output=head((feature-torch.from_numpy(mean))/torch.from_numpy(scale),base).numpy()[0]
    order=np.sort(output);predicted=int(output.argmax())
    if predicted and order[-1]-order[-2]<PROTOCOL['reject_margin']:predicted=0
    x0,y0,x1,y1=raw/[width,height,width,height]
    return dict(class_id=predicted,box=[float((x0+x1)/2),float((y0+y1)/2),float(x1-x0),float(y1-y0)],
                detection_score=float(scores[index]),logits=output.tolist())


def detector_evaluation(experiment, out):
    if out.exists():raise ValueError('use a new detector report filename')
    torch.set_num_threads(2)
    report=read_json(experiment/'REPORT.json')
    sources=source_fingerprint(LAB)
    if report['source_sha256']!=sources:raise ValueError('experiment source changed')
    cache=Path(report['cache_path']);info=validate_cache(cache)
    reference,backbone,parity=load_reference(Path(info['model_folder']))
    # Choose arm exclusively by the already-frozen public validation criterion.
    arm=max(report['experiments'],key=lambda name:(report['experiments'][name]['public_val']['gated']['balanced_accuracy'],
        -report['experiments'][name]['public_val']['gated']['false_target']))
    path=experiment/(arm+'.npz')
    if sha(path)!=report['experiments'][arm]['head_sha256']:raise ValueError('head changed')
    with np.load(path,allow_pickle=False) as arrays:
        head=ProjectHead(arm);head.linear.load_state_dict({'weight':torch.from_numpy(arrays['weight'].copy()),'bias':torch.from_numpy(arrays['bias'].copy())})
        mean,scale=arrays['mean'].copy(),arrays['scale'].copy()
    head.eval();items=[];identities=[]
    for source in info['source_manifests']:
        manifest=Path(source['path']);rows=[row for row in load_records(manifest) if row['split']=='val' and row['label_status']=='reviewed']
        before=fingerprint(manifest,rows)
        for row in rows:
            with Image.open(manifest.parent/row['image']) as image:rgb=center_rgb(image);size=image.size
            prediction=predict_image(rgb,reference,backbone,head,mean,scale,info['project_groups'])
            # Annotation is used only after image inference has returned.
            truth={'open':1,'fist':2}[row['boxes'][0]['class']] if row['boxes'] else 0
            box=record_box(row,size) if truth else None
            items.append(dict(origin=source['origin'],image=row['image'],expected=truth,expected_box=box,prediction=prediction,
                iou=normalized_iou(prediction['box'],box) if box and prediction['box'] is not None else 0.))
        if before!=fingerprint(manifest,rows):raise ValueError('evaluation data changed')
        identities.append(dict(origin=source['origin'],identity=before))
    summaries={}
    for origin in ('public','private'):
        own=[row for row in items if row['origin']==origin];positive=[row for row in own if row['expected']];negative=[row for row in own if not row['expected']]
        summaries[origin]=dict(images=len(own),targets=len(positive),negatives=len(negative),
            localization_iou50=sum(row['iou']>=.5 for row in positive),
            class_correct=sum(row['prediction']['class_id']==row['expected'] for row in positive),
            joint_correct=sum(row['iou']>=.5 and row['prediction']['class_id']==row['expected'] for row in positive),
            false_target=sum(row['prediction']['class_id']!=0 for row in negative))
    if sources!=source_fingerprint(LAB):raise ValueError('source changed during evaluation')
    result=dict(status='OFFLINE_FULL_FRAME_REFERENCE_DIAGNOSTIC',selected_arm=arm,selection='public_validation_only',
        source_sha256=sources,experiment_report_sha256=sha(experiment/'REPORT.json'),head_sha256=sha(path),
        dataset_identities=identities,summary=summaries,items=items,torch_onnx_max_error=parity,
        annotations_used_for_inference=False,private_is_historical_diagnostic=True,
        public_pretrained_overlap_possible=True,fpga_deployed=False,test_evaluated=False,board_tested=False,approved_for_gesture_use=False)
    out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(selected_arm=arm,summary=summaries),indent=2),flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    c = sub.add_parser('cache')
    c.add_argument('--public-manifest', type=Path, required=True)
    c.add_argument('--private-manifest', type=Path, required=True)
    c.add_argument('--models', type=Path, required=True)
    c.add_argument('--out', type=Path, required=True)
    c.add_argument('--quarter-turns',type=int,choices=[1,4],default=1)
    t = sub.add_parser('train')
    t.add_argument('--cache', type=Path, required=True)
    t.add_argument('--out', type=Path, required=True)
    d=sub.add_parser('detect-eval')
    d.add_argument('--experiment',type=Path,required=True)
    d.add_argument('--out',type=Path,required=True)
    args = parser.parse_args()
    if args.command == 'cache': prepare(args.public_manifest, args.private_manifest, args.models, args.out,args.quarter_turns)
    elif args.command=='train': train(args.cache, args.out)
    else: detector_evaluation(args.experiment,args.out)
