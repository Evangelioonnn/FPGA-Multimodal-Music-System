"""Export the fixed, unqualified crop diagnostic model. No training or selection."""
import json
from pathlib import Path
from reference import HERE, LAB, sha, weights


def write_mem(path, values, width):
    mask = (1 << width) - 1
    path.write_text(''.join(f'{int(v) & mask:0{width // 4}x}\n' for v in values), encoding='ascii')


def main():
    p, r = weights()
    out = HERE / 'assets'
    out.mkdir(exist_ok=True)
    assert p['w0'].shape == (8, 3, 3, 3) and p['w1'].shape == (8, 8, 3, 3)
    assert p['w2'].shape == (4, 512) and r['w0'].shape == (2, 512)
    conv = []
    for layer in (0, 1):
        w = p[f'w{layer}']
        for ci in range(w.shape[1]):
            for ky in range(3):
                for kx in range(3):
                    conv.append(sum((int(w[co, ci, ky, kx]) & 255) << (8 * co) for co in range(8)))
    fc = [sum((int(v) & 255) << (8 * co) for co, v in enumerate(
        [p['w2'][0, i], p['w2'][1, i], r['w0'][0, i], r['w0'][1, i]])) for i in range(512)]
    bias = [*p['b0'].tolist(), *p['b1'].tolist(), *p['b2'][:2].tolist(), *r['b0'].tolist()]
    shifts = [int(p['shift0']), int(p['shift1']), *([int(p['shift2'])] * 2), *([int(r['shift0'])] * 2)]
    write_mem(out / 'conv.mem', conv, 64)
    write_mem(out / 'fc.mem', fc, 32)
    write_mem(out / 'bias.mem', bias, 32)
    write_mem(out / 'shifts.mem', shifts, 8)
    # Explicit constants avoid the Gowin multi-read array-ROM lowering that
    # incorrectly discarded biases in the rejected first mapped implementation.
    constants='function signed [31:0] p20_bias;\ninput [4:0] index;\nbegin case(index)\n'
    constants+=''.join(f"5'd{i}:p20_bias=32'h{int(v)&0xffffffff:08x};\n" for i,v in enumerate(bias))
    constants+="default:p20_bias=32'd0;\nendcase end\nendfunction\n"
    (out/'bias_constants.vh').write_text(constants,encoding='ascii')
    identity = dict(schema='p20-standalone-parent-rom-1',
        parent=str(Path('checkpoints/two_stage_paired_20261022_rgb32_hard/quantized.npz').as_posix()),
        reject=str(Path('checkpoints/two_stage_paired_20261022_rgb32_hard/quantized.npz').as_posix()),
        parent_sha256=sha(LAB / 'checkpoints/two_stage_paired_20261022_rgb32_hard/quantized.npz'),
        reject_sha256=sha(LAB / 'checkpoints/two_stage_paired_20261022_rgb32_hard/quantized.npz'),
        preprocessing='RGB565 BE native32; bit replication RGB8; unsigned>>1; HWC RGB',
        network='conv3x3pad1s1 3->8,conv3x3pad1s1 8->8;shift floor clip0..127;avg4floor HWC512;FC4 signedQ4 clip[-128,127]',
        outputs=['OPEN', 'FIST', 'REJECT', 'ACCEPT'],
        composition='preserved trained parent conv0/1 and all four FC rows; no refitted reject substitution',
        gates=dict(pose_gap=8, acceptance_gap=8, pose_tie='OPEN then pose-gap reject'),
        rom_sha256={n: sha(out / n) for n in ('conv.mem', 'fc.mem', 'bias.mem', 'shifts.mem')})
    import hashlib
    canonical = json.dumps(identity, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode('ascii')
    digest = hashlib.sha256(canonical).hexdigest()
    manifest = dict(identity=identity, identity_sha256=digest, model_id_hex=digest[:32],
        hardware_bias_constants_sha256=sha(out/'bias_constants.vh'),
        hardware_bias_scope='case constants exactly encode bias.mem; implementation artifact outside canonical numerical model identity',
        model_id_recipe='first16 bytes SHA256(json.dumps(identity,sort_keys=True,separators=(comma,colon),ensure_ascii=True).encode(ascii)); bytes in digest order',
        source_sha256={name: sha(HERE / name) for name in ('export_model.py', 'reference.py')},
        rom_layout=dict(conv='99x64bits;layer0 27 taps thenlayer1 72 taps;ci,ky,kx;8 signed bytes,output0 LSB',
            fc='512x32bits;HWC featureaddress;4 signed bytes,OPEN LSB,FIST,REJECT,ACCEPT MSB',
            bias='20x32bits signed [conv0out0..7,conv1out0..7,FCout0..3]',
            shifts='6x8bits unsigned [conv0,conv1,FCopen,FCfist,FCreject,FCaccept]'),
        shifts=shifts, parameters=8*3*3*3+8*8*3*3+512*4+20,
        qualified=False, diagnostic=True, trained_here=False, threshold_tuned=False, old_files_modified=False)
    (out / 'MODEL.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    (out / 'model_id.vh').write_text('localparam [127:0] P20_CROP_MODEL_ID = 128\'h' + digest[:32] + ';\n', encoding='ascii')
    print(json.dumps(dict(model_id_hex=digest[:32], shifts=shifts, rom_sha256=identity['rom_sha256'])))


if __name__ == '__main__':
    main()
