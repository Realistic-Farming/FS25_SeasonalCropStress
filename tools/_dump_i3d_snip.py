import xml.etree.ElementTree as ET
from pathlib import Path

NS = "{http://www.i3d.giantssoftware.com}"


def load(path):
    return ET.fromstring(Path(path).read_text(encoding="utf-8", errors="replace"))


def localtag(el):
    t = el.tag
    if t.startswith("{"):
        return t.split("}", 1)[1]
    return t


def find_by_name(root, name):
    for el in root.iter():
        if el.get("name") == name:
            return el
    return None


def dump_tail(path, name, nchars=2500):
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    idx = text.find(f'name="{name}"')
    print(f"\n===== {Path(path).name} first '{name}' at {idx} =====")
    if idx < 0:
        return
    print(text[idx : idx + nchars])


dump_tail("vehicles/irrigatorPlay/i3d/Aggregat.i3d", "beltCollis", 1800)
dump_tail("vehicles/irrigatorPlay/i3d/T32.i3d", 'ai"', 1200)
dump_tail("vehicles/irrigatorPlay/i3d/T32.i3d", "aiCollisionTrigger", 800)
dump_tail("vehicles/irrigatorPlay/i3d/T32.i3d", "Pendel_CompJoint", 600)
dump_tail("vehicles/irrigatorPlay/i3d/T32.i3d", "wheelRightBack", 900)

root = load("vehicles/irrigatorPlay/i3d/T32.i3d")
att = find_by_name(root, "attacherR")
print("\nattacherR attribs:", att.attrib if att is not None else None)
ai = find_by_name(root, "ai")
print("ai attribs:", ai.attrib if ai is not None else None)
trig = find_by_name(root, "aiCollisionTrigger")
print("T32 aiCollisionTrigger attribs:", trig.attrib if trig is not None else None)

root_a = load("vehicles/irrigatorPlay/i3d/Aggregat.i3d")
trig_a = find_by_name(root_a, "aiCollisionTrigger")
print("Aggregat aiCollisionTrigger attribs:", trig_a.attrib if trig_a is not None else None)
belt = find_by_name(root_a, "beltCollis")
print("beltCollis attribs:", belt.attrib if belt is not None else None)
