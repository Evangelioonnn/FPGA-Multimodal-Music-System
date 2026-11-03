"""Offline independent reference. No camera/real-time audio dependency."""
from dataclasses import dataclass
import numpy as np

LAYERS = [(64, 1, 8, 3, 2), (32, 8, 12, 3, 2), (16, 12, 16, 3, 2),
          (8, 16, 24, 3, 2), (4, 24, 24, 3, 1), (4, 24, 7, 1, 1)]


def color_reference(rgb, min_area=8):
    rgb = np.asarray(rgb, dtype=np.int32)
    h, w, _ = rgb.shape
    r, g, b = rgb.transpose(2, 0, 1)
    masks = [(b >= 80) & (b-r >= 40) & (b-g >= 24),
             (g >= 70) & (g-r >= 24) & (g-b >= 16)]
    centers, counts = [], []
    for mask in masks:
        yy, xx = np.nonzero(mask)
        n = len(xx)
        counts.append(n)
        if not min_area <= n <= w*h//4:
            return dict(present=False, x=0, y=0, counts=counts)
        if xx.max()-xx.min()+1 > w//2 or yy.max()-yy.min()+1 > h//2:
            return dict(present=False, x=0, y=0, counts=counts)
        centers.append((int(xx.sum())//n, int(yy.sum())//n))
    x, y = [(centers[0][i]+centers[1][i])//2 for i in range(2)]
    return dict(present=True, x=x*255//(w-1), y=y*255//(h-1), counts=counts)


def rgb565_rgb(words):
    a = np.asarray(words, dtype=np.uint16)
    r, g, b = (a >> 11) & 31, (a >> 5) & 63, a & 31
    return np.stack(((r << 3) | (r >> 2), (g << 2) | (g >> 4),
                     (b << 3) | (b >> 2)), axis=-1).astype(np.uint8)


def conv_int(a, weight, bias, shift, stride, head=False):
    """HWC vs OIHW, explicit symmetric padding, int64 oracle accumulator."""
    h, w, ci = a.shape
    co, wi, k, _ = weight.shape
    assert ci == wi and 0 <= int(shift) <= 31
    padded = np.pad(a.astype(np.int64), ((k//2, k//2), (k//2, k//2), (0, 0)))
    out_h, out_w = (h+stride-1)//stride, (w+stride-1)//stride
    acc = np.broadcast_to(bias.astype(np.int64), (out_h, out_w, co)).copy()
    # Vectorized across spatial/output axes, independent of the hardware loop.
    for ky in range(k):
        for kx in range(k):
            patch = padded[ky:ky+out_h*stride:stride, kx:kx+out_w*stride:stride]
            acc += np.tensordot(patch, weight[:, :, ky, kx].astype(np.int64), axes=([2], [1]))
    if np.any(acc > 2147483647) or np.any(acc < -2147483648):
        raise ValueError('INT32 accumulator overflow')
    return np.clip(acc >> int(shift), -128 if head else 0, 127).astype(np.int8)


def infer_int(image, weights, biases, shifts):
    a = (np.asarray(image, dtype=np.uint8) >> 1).reshape(64, 64, 1).astype(np.int8)
    traces = []
    for i, (_, _, _, _, stride) in enumerate(LAYERS):
        a = conv_int(a, weights[i], biases[i], shifts[i], stride, head=i == 5)
        traces.append(a)
    return traces


def hard_sigmoid_q4(a):
    return np.clip(np.asarray(a, dtype=np.int32)+48, 0, 96)*255//96


def decode(head, object_threshold=160, class_margin=8):
    flat = np.asarray(head).reshape(16, 7).astype(np.int32)
    scores = hard_sigmoid_q4(flat[:, 4])
    cell = int(np.argmax(scores))  # deterministic lower cell wins ties
    v, score = flat[cell], int(scores[cell])
    if score < object_threshold:
        return dict(present=False, x=0, y=0, w=0, h=0, class_id=0, confidence=score, cell=cell)
    box = hard_sigmoid_q4(v[:4])
    x, y = (cell % 4 * 256+int(box[0])) >> 2, (cell // 4 * 256+int(box[1])) >> 2
    cls = 0 if abs(int(v[5])-int(v[6])) < class_margin else (1 if v[5] > v[6] else 2)
    return dict(present=True, x=x, y=y, w=int(box[2]), h=int(box[3]),
                class_id=cls, confidence=score, cell=cell)


@dataclass
class ExpressionReference:
    """One ms tick; snapshots can be sparse. Axes use relative pickup."""
    has_class: bool = False
    dwell_ms: int = 200
    loss_ms: int = 100
    gain: int = 256
    wet: int = 0
    bend: int = 0
    active: bool = False
    locked: bool = False
    age: int = 65535
    candidate: int = 0
    candidate_since: int = 0
    now: int = 0
    mode: bool = False
    mode_recovery: bool = False
    anchor_x: int = 0
    anchor_y: int = 0
    anchor_gain: int = 256
    anchor_xout: int = 0
    target_gain: int = 256
    target_x: int = 0

    def tick(self, snapshot=None, enable=True, mode=False, fault=False):
        self.now += 1
        self.age = min(65535, self.age+1)
        if not enable or fault or mode != self.mode:
            self.active, self.locked, self.candidate = False, False, 0
            self.target_gain, self.target_x = 256, 0
            if mode != self.mode: self.mode_recovery = True
            self.mode = mode
        elif self.mode_recovery:
            self.active, self.locked, self.candidate = False, False, 0
            self.target_gain, self.target_x = 256, 0
            if (self.gain, self.wet, self.bend) == (256, 0, 0): self.mode_recovery = False
        elif snapshot is not None:
            p, x, y, cls, conf = snapshot
            if p:
                if self.age > self.loss_ms:
                    self.candidate = 0
                self.age = 0
                valid_class = not self.has_class or cls in (1, 2) and conf >= 160
                accepted = not self.has_class
                if self.has_class:
                    if not valid_class:
                        self.candidate = 0
                    elif self.candidate != cls:
                        self.candidate, self.candidate_since = cls, self.now
                    else:
                        accepted = self.now-self.candidate_since >= self.dwell_ms
                if accepted:
                    if self.has_class and cls == 2:
                        self.locked = self.active
                        self.target_gain = self.gain
                        self.target_x = self.bend if mode else self.wet
                    elif not self.active or self.locked:
                        self.active, self.locked = True, False
                        self.anchor_x, self.anchor_y = x, y
                        self.anchor_gain = self.gain
                        self.anchor_xout = self.bend if mode else self.wet
                        self.target_gain, self.target_x = self.gain, self.anchor_xout
                    else:
                        dx, dy = x-self.anchor_x, self.anchor_y-y
                        if abs(dx) <= 2: dx = 0
                        if abs(dy) <= 2: dy = 0
                        self.target_gain = max(64, min(256, self.anchor_gain+dy))
                        self.target_x = max(-8 if mode else -64, min(8 if mode else 64,
                                             self.anchor_xout+(dx >> (4 if mode else 1))))
                elif self.active:  # pause while classification is unstable
                    self.target_gain, self.target_x = self.gain, self.bend if mode else self.wet
            else:
                self.candidate = 0
        if self.age > self.loss_ms:
            self.active, self.locked, self.candidate = False, False, 0
            self.target_gain, self.target_x = 256, 0
        def step(v, target): return v+(target > v)-(target < v)
        self.gain = step(self.gain, self.target_gain)
        self.wet = step(self.wet, 0 if mode else self.target_x)
        self.bend = step(self.bend, self.target_x if mode else 0)
        return self.gain, self.wet, self.bend, self.active, self.locked
