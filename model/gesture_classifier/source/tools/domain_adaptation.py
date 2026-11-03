"""Bounded self-capture adaptation and annotation-free fixed-window replay.

Only private TRAIN records affect calibration/optimization. Historical private
VAL is a development diagnostic, never a fresh test. Neither network nor this
Python replay is FPGA firmware; the color tracking/automatic ROI finder is not
implemented by this experiment.
"""
import argparse
from collections import Counter
import csv
import hashlib
import json
import math
from pathlib import Path
import random
import shutil
import time

import numpy as np
from PIL import Image, ImageDraw
import torch
from torch.nn import functional as F

from dataset import fingerprint, load_records, training_partitions
from provenance import source_fingerprint
from pretrained_reference import center_rgb
from roi_classifier import (FORMAT, ROIClassifier, crop_rgb, record_box, sample32,
                            decode, float_logits, integer_logits, metrics, quantize)

LAB = Path(__file__).resolve().parents[1]
PROTOCOL = dict(epochs=80, learning_rate=.0002, domain_repeat=16, batch_size=32,
                seed=20261016, weight_decay=.0005, margin_q4=8,
                checkpoint_selection='final_epoch_only', window_context=1.10)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def check_isolation(sources):
    """Check aliases too: the same video cannot cross splits under new groups."""
    seen = {}
    for manifest, rows in sources:
        for row in rows:
            for key in (('group', row['group']), ('image', sha(manifest.parent / row['image'])),
                        ('video', row.get('source_video_sha256'))):
                if key[1] and seen.setdefault(key, row['split']) != row['split']:
                    raise ValueError('cross-split leakage: ' + key[0])


def calibration(boxes, context=1.10):
    """Square covering training-hand union plus a fixed margin, inside ROI."""
    values = np.asarray(boxes, dtype=np.float64)
    if values.ndim != 2 or values.shape[1] != 4 or not len(values):
        raise ValueError('calibration needs training hand boxes')
    if not np.isfinite(values).all() or (values[:, 2:] <= 0).any() or context < 1:
        raise ValueError('invalid calibration boxes/context')
    low = (values[:, :2] - values[:, 2:] / 2).min(axis=0)
    high = (values[:, :2] + values[:, 2:] / 2).max(axis=0)
    if (low < -1e-6).any() or (high > 1+1e-6).any():
        raise ValueError('hand outside central ROI')
    side = min(1., float((high-low).max()) * context)
    center = np.clip((low+high)/2, side/2, 1-side/2)
    return [float(center[0]), float(center[1]), side, side]


def calibrate_train(manifest, rows):
    boxes = []
    for row in rows:
        if row['split'] != 'train' or not row['boxes']:
            continue
        with Image.open(manifest.parent / row['image']) as image:
            boxes.append(record_box(row, image.size))
    return calibration(boxes, PROTOCOL['window_context'])


def coverage(box, window):
    box = np.asarray(box, dtype=np.float64)
    window = np.asarray(window, dtype=np.float64)
    intersection = np.maximum(0, np.minimum(box[:2]+box[2:]/2, window[:2]+window[2:]/2)
                              - np.maximum(box[:2]-box[2:]/2, window[:2]-window[2:]/2))
    return float(intersection.prod()/box[2:].prod())


def private_inputs(manifest, rows, window):
    oracle, fixed, labels, metadata = [], [], [], []
    for row in rows:
        with Image.open(manifest.parent / row['image']) as image:
            rgb = center_rgb(image)
            box = record_box(row, image.size)
        # The fixed input does not consult any per-frame annotation.
        fixed.append(sample32(crop_rgb(rgb, window, context=1.0)))
        oracle.append(sample32(crop_rgb(rgb, box)))
        label = {'open': 1, 'fist': 2}[row['boxes'][0]['class']] if row['boxes'] else 0
        labels.append(label)
        metadata.append(dict(image=row['image'], split=row['split'], group=row['group'],
                             expected=label, hand_coverage=coverage(box, window) if box else None))
    return dict(oracle=np.stack(oracle), fixed=np.stack(fixed), labels=np.array(labels, np.int64), rows=metadata)


def load_public(cache):
    info = read_json(cache.with_suffix('.json'))
    if sha(cache) != info['cache_sha256'] or info['format'] != FORMAT:
        raise ValueError('public cache changed or wrong format')
    manifest = Path(info['source_manifest'])
    rows = load_records(manifest)
    training_partitions(rows, pilot=True, allow_draft=True)
    if fingerprint(manifest, rows) != info['dataset']:
        raise ValueError('public source changed')
    with np.load(cache, allow_pickle=False) as archive:
        images, labels = archive['images'].copy(), archive['labels'].copy()
    if len(rows) != len(images) or len(rows) != len(info['rows']):
        raise ValueError('public cache row count mismatch')
    for row, meta, label in zip(rows, info['rows'], labels):
        expected = {'open': 1, 'fist': 2}[row['boxes'][0]['class']] if row['boxes'] else 0
        if (row['image'], row['split'], expected) != (meta['image'], meta['split'], int(label)):
            raise ValueError('public cache labels/order changed')
    return images, labels, info, manifest, rows


def augmented(images, rng):
    result = []
    for image in images:
        value = image.transpose(1, 2, 0)
        if rng.random() < .5:
            value = value[:, ::-1]
        # Small displacement uses edge padding; never wrap a departing finger.
        value = np.pad(value, ((2, 2), (2, 2), (0, 0)), mode='edge')
        x, y = rng.integers(0, 5, 2)
        value = value[y:y+32, x:x+32]
        value = np.clip(value.astype(np.float32)*rng.uniform(.85, 1.15)+rng.uniform(-8, 8), 0, 255).astype(np.uint8)
        result.append(value.transpose(2, 0, 1).copy())
    return torch.from_numpy((np.stack(result) >> 1).astype(np.float32)/128)


def fit(initial, public_images, public_labels, own_images, own_labels, out):
    random.seed(PROTOCOL['seed'])
    np.random.seed(PROTOCOL['seed'])
    torch.manual_seed(PROTOCOL['seed'])
    rng = np.random.default_rng(PROTOCOL['seed'])
    model = ROIClassifier(False)
    model.load_state_dict(torch.load(initial / 'weights.pt', map_location='cpu', weights_only=True))
    images = np.concatenate((public_images, own_images))
    labels = np.concatenate((public_labels, own_labels))
    schedule = np.concatenate((np.arange(len(public_images)),
                               np.tile(np.arange(len(own_images))+len(public_images), PROTOCOL['domain_repeat'])))
    optimizer = torch.optim.AdamW(model.parameters(), lr=PROTOCOL['learning_rate'], weight_decay=PROTOCOL['weight_decay'])
    history = []
    started = time.monotonic()
    for epoch in range(PROTOCOL['epochs']):
        rate = min(1, (epoch+1)/5)*(.05+.95*(1+math.cos(math.pi*epoch/(PROTOCOL['epochs']-1)))/2)
        for group in optimizer.param_groups:
            group['lr'] = PROTOCOL['learning_rate'] * rate
        order = rng.permutation(schedule)
        losses = []
        model.train()
        for begin in range(0, len(order), PROTOCOL['batch_size']):
            indices = order[begin:begin+PROTOCOL['batch_size']]
            optimizer.zero_grad()
            loss = F.cross_entropy(model(augmented(images[indices], rng)), torch.from_numpy(labels[indices]))
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 10)
            optimizer.step()
            losses.append(float(loss.detach()))
        if epoch == 0 or (epoch+1) % 20 == 0:
            entry = dict(epoch=epoch+1, training_loss=float(np.mean(losses)))
            print(json.dumps(dict(arm=out.name, **entry)), flush=True)
            history.append(entry)
    model.eval()
    quantized = quantize(model)
    out.mkdir()
    torch.save(model.state_dict(), out / 'weights.pt')
    np.savez(out / 'roi_classifier_int8.npz', **quantized)
    return model, quantized, dict(history=history, elapsed_seconds=time.monotonic()-started,
                                 unique_public_train=len(public_images), unique_private_train=len(own_images),
                                 scheduled_training_samples_per_epoch=len(schedule), parameters=sum(p.numel() for p in model.parameters()))


def evaluate(model, quantized, images, labels, metadata=None):
    floating = float_logits(model, images)
    integer = np.stack([integer_logits(image, quantized) for image in images])
    result = dict(float=metrics(floating, labels), int8=metrics(integer, labels))
    if metadata is not None:
        result['items'] = [dict(row, int8_logits=logits.tolist(), int8_predicted=int(decode(logits)),
                               float_predicted=int(decode(fl))) for row, logits, fl in zip(metadata, integer, floating)]
    return result


def gallery(manifest, rows, window, items, out):
    canvas = Image.new('RGB', (1250, 50 + math.ceil(len(rows)/5)*195), 'white')
    draw = ImageDraw.Draw(canvas)
    draw.text((8, 6), 'FIXED WINDOW: set from batch1 only / cyan=input window / yellow=GT for review only', fill='black')
    draw.text((8, 24), 'Right: actual RGB32 input. 0=other, 1=open, 2=fist. Historical batch2; NOT board acceptance.', fill='black')
    for i, (row, item) in enumerate(zip(rows, items)):
        with Image.open(manifest.parent / row['image']) as image:
            rgb = center_rgb(image)
            box = record_box(row, image.size)
        left, top = (i % 5)*250, 50+(i//5)*195
        overview = Image.fromarray(rgb).resize((128, 128))
        pen = ImageDraw.Draw(overview)
        for bounds, color in [(window, 'cyan'), (box, 'yellow')]:
            if bounds:
                x, y, w, h = bounds
                pen.rectangle(((x-w/2)*128, (y-h/2)*128, (x+w/2)*128, (y+h/2)*128), outline=color, width=2)
        canvas.paste(overview, (left, top))
        sample = sample32(crop_rgb(rgb, window, context=1.0)).transpose(1, 2, 0)
        canvas.paste(Image.fromarray(sample).resize((112, 112), Image.Resampling.NEAREST), (left+134, top))
        good = item['expected'] == item['int8_predicted']
        draw.text((left+3, top+132), Path(row['image']).stem, fill='black')
        draw.text((left+3, top+148), f"true={item['expected']} pred={item['int8_predicted']} logits={item['int8_logits']}", fill='darkgreen' if good else 'red')
        cov = item['hand_coverage']
        draw.text((left+3, top+166), f'GT hand coverage={cov:.2f}' if cov is not None else 'No target annotated', fill='black')
    canvas.save(out)


def train_adaptation(cache, private_manifest, initial, out):
    if out.exists():
        raise ValueError('use a new output directory')
    torch.set_num_threads(2)
    sources = source_fingerprint(LAB)
    public_images, public_labels, cache_info, public_manifest, public_rows = load_public(cache)
    private_rows = load_records(private_manifest)
    training_partitions(private_rows, pilot=True)
    check_isolation([(public_manifest, public_rows), (private_manifest, private_rows)])
    data_identity = fingerprint(private_manifest, private_rows)
    initial_report = read_json(initial / 'TRAINING_REPORT.json')
    if initial_report['format'] != FORMAT or initial_report['distillation']:
        raise ValueError('expected the local ordinary-supervised ROI32 baseline')
    initial_identity = {name: sha(initial / name) for name in ('weights.pt', 'TRAINING_REPORT.json', 'roi_classifier_int8.npz')}
    train_rows = [row for row in private_rows if row['split'] == 'train']
    window = calibrate_train(private_manifest, private_rows)
    own = private_inputs(private_manifest, train_rows, window)
    train_idx = np.array([i for i, row in enumerate(public_rows) if row['split'] == 'train'])
    val_idx = np.array([i for i, row in enumerate(public_rows) if row['split'] == 'val'])
    out.mkdir(parents=True)
    protocol = dict(protocol=PROTOCOL, window=window, calibrated_with='private_train_only',
                    source_sha256=sources, private_dataset=data_identity, public_cache_sha256=sha(cache),
                    initial_checkpoint_sha256=initial_identity, private_val_used_for_optimization=False)
    (out / 'FROZEN_PROTOCOL.json').write_text(json.dumps(protocol, indent=2)+'\n', encoding='utf-8')
    for relative in sources:
        destination = out / 'source' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(LAB / relative, destination)
    experiments = {}
    # Both arms/epochs are specified before reading any validation scores.
    for arm in ('oracle', 'fixed'):
        model, quantized, training = fit(initial, public_images[train_idx], public_labels[train_idx],
                                        own[arm], own['labels'], out / arm)
        experiments[arm] = dict(training=training)
        # No validation metric is consulted by fit() or used to select epochs.
        all_private = private_inputs(private_manifest, private_rows, window)
        experiments[arm]['public_val_oracle'] = evaluate(model, quantized, public_images[val_idx], public_labels[val_idx])
        for split in ('train', 'val'):
            indices = np.array([i for i, row in enumerate(private_rows) if row['split'] == split])
            meta = [all_private['rows'][i] for i in indices]
            for view in ('oracle', 'fixed'):
                experiments[arm][f'private_{split}_{view}'] = evaluate(model, quantized, all_private[view][indices], all_private['labels'][indices], meta)
        val_rows = [row for row in private_rows if row['split'] == 'val']
        gallery(private_manifest, val_rows, window, experiments[arm]['private_val_fixed']['items'], out / arm / 'FIXED_WINDOW_VAL.png')
        experiments[arm]['weights_sha256'] = sha(out / arm / 'weights.pt')
        experiments[arm]['int8_sha256'] = sha(out / arm / 'roi_classifier_int8.npz')
    if sources != source_fingerprint(LAB) or data_identity != fingerprint(private_manifest, private_rows):
        raise ValueError('source/private data changed during experiment')
    if sha(cache) != protocol['public_cache_sha256'] or load_public(cache)[2]['dataset'] != cache_info['dataset']:
        raise ValueError('public data changed during experiment')
    if initial_identity != {name: sha(initial / name) for name in initial_identity}:
        raise ValueError('initial checkpoint changed')
    report = dict(status='PRIVATE_DOMAIN_ADAPTATION_DIAGNOSTIC_ONLY', format=FORMAT,
                  **protocol, private_manifest=str(private_manifest.resolve()),
                  public_cache=str(cache.resolve()), experiments=experiments,
                  window_hand_coverage={split: dict(targets=len(covs), fully_covered=sum(c >= .999 for c in covs),
                      at_least_95_percent=sum(c >= .95 for c in covs))
                      for split in ('train', 'val')
                      for covs in [[row['hand_coverage'] for row in all_private['rows'] if row['split'] == split and row['expected']]]},
                  private_validation_is_historical=True, test_evaluated=False, fpga_rtl_implemented=False,
                  synthesis=False, pnr=False, board_tested=False, approved_for_gesture_use=False)
    (out / 'REPORT.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(dict(status=report['status'], window=window, coverage=report['window_hand_coverage'],
        experiments={name: {key: value for key, value in entry.items() if key not in ('private_train_fixed', 'private_train_oracle') and key.startswith(('public_', 'private_'))}
                     for name, entry in experiments.items()}), indent=2), flush=True)


def replay(experiment, video_root, video_metadata, out):
    """Read local phone videos at 10Hz. Predictions only: filenames are not GT."""
    if out.exists():
        raise ValueError('use a new replay output directory')
    import cv2
    report = read_json(experiment / 'REPORT.json')
    sources = source_fingerprint(LAB)
    if sources != report['source_sha256']:
        raise ValueError('experiment source changed')
    model_path = experiment / 'fixed/roi_classifier_int8.npz'
    if sha(model_path) != report['experiments']['fixed']['int8_sha256']:
        raise ValueError('model changed')
    with np.load(model_path, allow_pickle=False) as archive:
        q = {key: archive[key].copy() for key in archive.files}
    videos = read_json(video_metadata)
    # A metadata manifest is required; never enumerate or process unrelated videos.
    if len(videos) != 8 or {entry['file'] for entry in videos} != {f'{kind}{batch}.mp4' for kind in ('open', 'fist', 'empty', 'transition') for batch in (1, 2)}:
        raise ValueError('expected the eight recorded capture videos')
    for entry in videos:
        path = video_root / entry['file']
        if path.name != entry['file'] or sha(path) != entry['sha256']:
            raise ValueError('video identity changed')
    out.mkdir(parents=True)
    summaries = []
    for entry in videos:
        cap = cv2.VideoCapture(str(video_root / entry['file']))
        if not cap.isOpened():
            raise ValueError('cannot open video')
        fps = cap.get(cv2.CAP_PROP_FPS)
        if not math.isfinite(fps) or abs(fps-entry['fps']) > .1:
            raise ValueError('unexpected video timing')
        frames, predictions, samples = 0, [], []
        next_sample = 0.
        while True:
            ok, bgr = cap.read()
            if not ok:
                break
            now = frames/fps
            frames += 1
            if now+1e-6 < next_sample:
                continue
            next_sample += .1
            if list(bgr.shape[1::-1]) != entry['size']:
                raise ValueError('decoded orientation/size differs from reviewed capture')
            rgb = center_rgb(Image.fromarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)))
            sample = sample32(crop_rgb(rgb, report['window'], context=1.0))
            logits = integer_logits(sample, q)
            predicted = int(decode(logits))
            values = np.sort(logits.astype(np.int32))
            predictions.append(dict(time_ms=round(now*1000), frame=frames-1, predicted=predicted,
                                    other_q4=int(logits[0]), open_q4=int(logits[1]), fist_q4=int(logits[2]), margin_q4=int(values[-1]-values[-2])))
            if len(predictions) == 1 or len(predictions) % 50 == 0:
                samples.append((sample, predictions[-1]))
        cap.release()
        if not predictions or frames/fps < entry['duration']-.5:
            raise ValueError('video decode truncated')
        with (out / (Path(entry['file']).stem+'.csv')).open('w', newline='', encoding='utf-8') as handle:
            writer = csv.DictWriter(handle, fieldnames=list(predictions[0]))
            writer.writeheader();writer.writerows(predictions)
        canvas = Image.new('RGB', (max(1, len(samples))*132, 160), 'white')
        pen = ImageDraw.Draw(canvas)
        for i, (sample, prediction) in enumerate(samples):
            canvas.paste(Image.fromarray(sample.transpose(1, 2, 0)).resize((128, 128), Image.Resampling.NEAREST), (i*132, 0))
            pen.text((i*132, 132), f"{prediction['time_ms']}ms class={prediction['predicted']}", fill='black')
        canvas.save(out / (Path(entry['file']).stem+'_INPUTS.png'))
        summary = dict(file=entry['file'], sha256=entry['sha256'], source_batch=entry['batch'],
                       duration_seconds=frames/fps, source_frames=frames, sampled_frames=len(predictions),
                       predicted_counts=dict(Counter(str(row['predicted']) for row in predictions)),
                       adjacent_class_changes=sum(a['predicted'] != b['predicted'] for a, b in zip(predictions, predictions[1:])),
                       ground_truth_annotated=False, accuracy=None, false_action_rate=None)
        summaries.append(summary)
        print(json.dumps(summary), flush=True)
    if sources != source_fingerprint(LAB):
        raise ValueError('source changed during replay')
    replay_report = dict(status='FIXED_WINDOW_OFFLINE_REPLAY_ONLY', model_sha256=sha(model_path),
        experiment_report_sha256=sha(experiment / 'REPORT.json'), source_sha256=sources,
        video_metadata_sha256=sha(video_metadata), window=report['window'], sampling_hz=10,
        inference_uses_annotations=False, position_output=False, gesture_controller_executed=False,
        no_hand_or_transition_ground_truth_generated_from_filenames=True,
        videos=summaries, board_tested=False, approved_for_gesture_use=False)
    (out / 'REPLAY.json').write_text(json.dumps(replay_report, indent=2)+'\n', encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    train_parser = sub.add_parser('train')
    train_parser.add_argument('--public-cache', type=Path, required=True)
    train_parser.add_argument('--private-manifest', type=Path, required=True)
    train_parser.add_argument('--initial', type=Path, required=True)
    train_parser.add_argument('--out', type=Path, required=True)
    replay_parser = sub.add_parser('replay')
    replay_parser.add_argument('--experiment', type=Path, required=True)
    replay_parser.add_argument('--video-root', type=Path, required=True)
    replay_parser.add_argument('--video-metadata', type=Path, required=True)
    replay_parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'train':
        train_adaptation(args.public_cache, args.private_manifest, args.initial, args.out)
    else:
        replay(args.experiment, args.video_root, args.video_metadata, args.out)
