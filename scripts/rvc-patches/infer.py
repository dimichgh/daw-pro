"""Run one voice conversion through the PATCHED MLX path.

  python3 scripts/rvc-patches/infer.py <model.npz> <input.wav> <output.wav> [index.index]

env:
  RVC_MLX_NOISE_SCALE   default 0.66666 (the RVC PyTorch reference value)
"""
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from shadow import install  # noqa: E402

if len(sys.argv) < 4:
    sys.exit(__doc__)

model, inp, outp = sys.argv[1], sys.argv[2], sys.argv[3]
idx = sys.argv[4] if len(sys.argv) > 4 else ""
rate = 0.75 if idx else 0.0

install()

from rvc_mlx.infer.infer_mlx import RVC_MLX  # noqa: E402

t0 = time.perf_counter()
eng = RVC_MLX(model)
t1 = time.perf_counter()
eng.infer(inp, outp, pitch=0, f0_method="rmvpe", index_path=idx, index_rate=rate)
t2 = time.perf_counter()
print(f"RESULT load={t1-t0:.2f}s infer={t2-t1:.2f}s index_rate={rate} -> {outp}")
