"""Independent INT64 offline oracle; never opens serial or performs training.

The original frozen NPZ tensors are evaluated directly, without reading the RTL
ROM layout. Images must be the saved native RGB56532 plane, not a preview crop.
"""
import hashlib
import json
from pathlib import Path
import sys
import zlib

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[2]
ROOT = LAB.parents[1]
sys.path.insert(0, str(ROOT / 'tmp/torch_cpu'))
import numpy as np

PARENT = LAB / 'checkpoints/two_stage_paired_20261022_rgb32_hard/quantized.npz'
REJECT = PARENT


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def weights():
    with np.load(PARENT, allow_pickle=False) as z:
        p = {k: z[k].copy() for k in z.files}
    r = dict(w0=p['w2'][2:].copy(), b0=p['b2'][2:].copy(), shift0=p['shift2'])
    return p, r


def expand_rgb565(data):
    if len(data) != 2048:
        raise ValueError('one saved 32x32 RGB565 BE image (2048 bytes) required')
    w = np.frombuffer(data, dtype='>u2').astype(np.uint16).reshape(32, 32)
    r, g, b = (w >> 11) & 31, (w >> 5) & 63, w & 31
    return np.stack(((r << 3) | (r >> 2), (g << 2) | (g >> 4),
                     (b << 3) | (b >> 2)), axis=-1).astype(np.uint8)


def convolution(x, w, b, shift):
    """Signed INT64 HWC convolution, explicit pad and arithmetic floor shift."""
    x = np.pad(x.astype(np.int64), ((1, 1), (1, 1), (0, 0)))
    out = np.broadcast_to(b.astype(np.int64), (32, 32, len(b))).copy()
    for ky in range(3):
        for kx in range(3):
            out += x[ky:ky + 32, kx:kx + 32, :] @ w[:, :, ky, kx].astype(np.int64).T
    return np.clip(out >> int(shift), 0, 127).astype(np.uint8)


def infer_rgb565(data, return_layers=False):
    p, r = weights()
    q7 = expand_rgb565(data) >> 1
    c0 = convolution(q7, p['w0'], p['b0'], p['shift0'])
    c1 = convolution(c0, p['w1'], p['b1'], p['shift1'])
    pooled = (c1.astype(np.int64).reshape(8, 4, 8, 4, 8).sum((1, 3)) // 16).astype(np.uint8)
    feat = pooled.reshape(512).astype(np.int64)
    pose = (p['w2'][:2].astype(np.int64) @ feat + p['b2'][:2].astype(np.int64)) >> int(p['shift2'])
    accept = (r['w0'].astype(np.int64) @ feat + r['b0'].astype(np.int64)) >> int(r['shift0'])
    logits = np.clip(np.concatenate((pose, accept)), -128, 127).astype(np.int8)
    li = [int(v) for v in logits]
    posegap, acceptgap = abs(li[0] - li[1]), li[3] - li[2]
    reason = int(posegap < 8) | (int(acceptgap < 8) << 1)
    final = 0 if reason else (1 if li[0] >= li[1] else 2)
    result = dict(logits=li, input_crc=zlib.crc32(q7.tobytes()),
                  feature_crc=zlib.crc32(pooled.tobytes()), head_crc=zlib.crc32(logits.tobytes()),
                  pose_gap=posegap, accept_gap=acceptgap, final=final, reason=reason)
    if return_layers:
        result.update(q7=q7, conv0=c0, conv1=c1, pooled=pooled)
    return result


def model_id():
    m = json.loads((HERE / 'assets/MODEL.json').read_text(encoding='utf-8'))
    canonical = json.dumps(m['identity'], sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode('ascii')
    digest = hashlib.sha256(canonical).hexdigest()
    if digest != m['identity_sha256'] or digest[:32] != m['model_id_hex']:
        raise ValueError('model identity manifest mismatch')
    if sha(HERE/'assets/bias_constants.vh') != m['hardware_bias_constants_sha256']:
        raise ValueError('bias constant implementation differs from manifest')
    import re
    explicit=re.findall(r"5'd(\d+):p20_bias=32'h([0-9a-f]{8});",(HERE/'assets/bias_constants.vh').read_text())
    memory=(HERE/'assets/bias.mem').read_text().splitlines()
    if explicit != [(str(i),v) for i,v in enumerate(memory)]:
        raise ValueError('explicit bias constants differ from numerical bias ROM')
    for name, expected in m['identity']['rom_sha256'].items():
        if sha(HERE / 'assets' / name) != expected:
            raise ValueError('model ROM differs from manifest: ' + name)
    if sha(PARENT) != m['identity']['parent_sha256'] or sha(REJECT) != m['identity']['reject_sha256']:
        raise ValueError('frozen original weights differ from manifest')
    return digest[:32]
