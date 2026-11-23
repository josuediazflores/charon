"""Compatibility with existing CMO registrations and operator tools."""
from feature_control import CONFIG_DIR, STATE, FeatureControl, guard_name, pairs_from, systemctl

MANIFEST = CONFIG_DIR / "cmo-units.json"
GUARD_NAME = guard_name("cmo")


class CmoControl(FeatureControl):
    def __init__(self, manifest=MANIFEST, state=STATE, run=systemctl):
        super().__init__("cmo", manifest, state, run)
