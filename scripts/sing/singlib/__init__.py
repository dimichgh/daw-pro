"""Shared code for DAW Pro's singing sidecar (p2-sing-b).

Standard-library only, Python 3.9 compatible: `refusals`, `schema`, `score`, `wavio`, `pins`, `http`, `langs`.
The stub (`stub_server.py`) runs these under the system `/usr/bin/python3`, so the stub and the real facade
share ONE request schema and ONE refusal table; they cannot drift apart.

Facade only (the runtime venv, Python 3.10): `phonemes` (g2p_en; g2pM and ToJyutping for facadeVersion 2's
Chinese words, imported on first use), `engine` (torch + upstream SoulX-Singer).
Those import their third-party packages lazily, so nothing here drags them into the stub.
"""

FACADE_VERSION = 1
