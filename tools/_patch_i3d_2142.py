"""Patch Aggregat.i3d and T32.i3d for BUILD 21:42 controlTrigger + hitch + chocks."""
from pathlib import Path

AGG = Path("vehicles/irrigatorPlay/i3d/Aggregat.i3d")
T32 = Path("vehicles/irrigatorPlay/i3d/T32.i3d")

CONTROL_AGG = (
    '        <Shape name="controlTrigger" translation="0 1.2 0" shapeId="14" '
    'kinematic="true" compound="true" trigger="true" '
    'collisionFilterGroup="0x20000000" collisionFilterMask="0x100000" '
    'castsShadows="true" receiveShadows="true" nonRenderable="true" '
    'materialIds="5" nodeId="901"/>\n'
)

CONTROL_T32 = (
    '        <Shape name="controlTrigger" translation="0 1.2 0" shapeId="2" '
    'kinematic="true" compound="true" trigger="true" '
    'collisionFilterGroup="0x20000000" collisionFilterMask="0x100000" '
    'castsShadows="true" receiveShadows="true" nonRenderable="true" '
    'materialIds="6" nodeId="902"/>\n'
)

HITCH = (
    '      <TransformGroup name="attacherImplement" translation="0.0501453 0.40 0.765723" '
    'rotation="0 90 0" nodeId="903"/>\n'
    '      <TransformGroup name="topReferenceNode" translation="0.0501453 0.90 0.765723" '
    'rotation="0 90 0" nodeId="904"/>\n'
)

CHOCKS = (
    '        <TransformGroup name="wheelChock01_01" translation="-0.85 0.02 -0.18" nodeId="905"/>\n'
    '        <TransformGroup name="wheelChock01_02" translation="-0.85 0.02 0.28" nodeId="906"/>\n'
)


def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f"MISSING snippet: {label}")
    if text.count(old) != 1:
        raise SystemExit(f"AMBIGUOUS snippet ({text.count(old)}): {label}")
    return text.replace(old, new, 1)


agg = AGG.read_text(encoding="utf-8")
old_agg = (
    '          <Shape shapeId="15" name="beltCol4" translation="0.266962 2.13328 0.285218" '
    'scale="0.1 0.1 1" nodeId="70" materialIds="4" nonRenderable="true" distanceBlending="false"/>\n'
    "        </TransformGroup>\n"
    "      </TransformGroup>"
)
new_agg = (
    '          <Shape shapeId="15" name="beltCol4" translation="0.266962 2.13328 0.285218" '
    'scale="0.1 0.1 1" nodeId="70" materialIds="4" nonRenderable="true" distanceBlending="false"/>\n'
    "        </TransformGroup>\n"
    + CONTROL_AGG
    + "      </TransformGroup>"
)
agg = must_replace(agg, old_agg, new_agg, "Aggregat controlTrigger")
if 'name="controlTrigger"' not in agg:
    raise SystemExit("Aggregat controlTrigger not written")
AGG.write_text(agg, encoding="utf-8")
print("patched", AGG)

t32 = T32.read_text(encoding="utf-8")
old_ai = (
    'name="aiCollisionTrigger" translation="0 1.10138 -0.489935" kinematic="true" '
    'compound="true" trigger="true" collisionMask="1056768" nodeId="61" materialIds="6" '
    'castsShadows="true" receiveShadows="true" nonRenderable="true"/>\n'
    "      </TransformGroup>"
)
new_ai = (
    'name="aiCollisionTrigger" translation="0 1.10138 -0.489935" kinematic="true" '
    'compound="true" trigger="true" collisionMask="1056768" nodeId="61" materialIds="6" '
    'castsShadows="true" receiveShadows="true" nonRenderable="true"/>\n'
    + CONTROL_T32
    + "      </TransformGroup>"
)
t32 = must_replace(t32, old_ai, new_ai, "T32 controlTrigger")

old_chock = (
    '          <TransformGroup name="wheelRightBackDrive" nodeId="193"/>\n'
    "        </TransformGroup>\n"
    "      </TransformGroup>\n"
    '      <TransformGroup name="cameras" nodeId="120">'
)
new_chock = (
    '          <TransformGroup name="wheelRightBackDrive" nodeId="193"/>\n'
    "        </TransformGroup>\n"
    + CHOCKS
    + "      </TransformGroup>\n"
    '      <TransformGroup name="cameras" nodeId="120">'
)
t32 = must_replace(t32, old_chock, new_chock, "T32 wheelChocks")

old_hitch = (
    '<TransformGroup name="Pendel_CompJoint" translation="0.0501453 1.21676 0.114714" nodeId="134"/>\n'
    "    </Shape>"
)
new_hitch = (
    '<TransformGroup name="Pendel_CompJoint" translation="0.0501453 1.21676 0.114714" nodeId="134"/>\n'
    + HITCH
    + "    </Shape>"
)
t32 = must_replace(t32, old_hitch, new_hitch, "T32 hitch nodes")
T32.write_text(t32, encoding="utf-8")
print("patched", T32)
