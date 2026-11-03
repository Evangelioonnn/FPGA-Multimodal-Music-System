"""Source identity for software/RTL tests; physical constraints qualify separately."""
import hashlib


def source_fingerprint(lab):
    return {p.relative_to(lab).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
            for sub in ('rtl','sim','tools','tests') for p in sorted((lab/sub).glob('*')) if p.is_file()}
