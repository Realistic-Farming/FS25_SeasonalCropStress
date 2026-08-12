import xml.etree.ElementTree as ET
from pathlib import Path

NS = "{http://www.i3d.giantssoftware.com}"


def load(path):
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    return ET.fromstring(text)


def localtag(el):
    t = el.tag
    if t.startswith("{"):
        return t.split("}", 1)[1]
    return t


def dump_named(path, names):
    root = load(path)
    print("===", Path(path).name, "===")
    for el in root.iter():
        n = el.get("name")
        if n in names:
            print(
                f"  {localtag(el)} name={n} trans={el.get('translation')} "
                f"scale={el.get('scale')} shapeId={el.get('shapeId')} "
                f"dyn={el.get('dynamic')} kin={el.get('kinematic')} "
                f"compound={el.get('compound')} trigger={el.get('trigger')} "
                f"cmask={el.get('collisionMask')} cfg={el.get('collisionFilterGroup')} "
                f"cfm={el.get('collisionFilterMask')} mat={el.get('materialIds')} "
                f"children={len(list(el))}"
            )
            for j, ch in enumerate(el):
                print(
                    f"      child[{j}] {localtag(ch)} name={ch.get('name')} "
                    f"shapeId={ch.get('shapeId')} trans={ch.get('translation')} "
                    f"scale={ch.get('scale')} kin={ch.get('kinematic')} "
                    f"trig={ch.get('trigger')} cmask={ch.get('collisionMask')}"
                )


dump_named(
    Path("vehicles/irrigatorPlay/i3d/Aggregat.i3d"),
    {"transform", "aiCollisionTrigger", "beltCollis", "Aggregat_main", "ai"},
)
print()
dump_named(
    Path("vehicles/irrigatorPlay/i3d/T32.i3d"),
    {
        "ai",
        "aiCollisionTrigger",
        "RootCol",
        "RegnerCol",
        "attacherR",
        "wheels2",
        "wheelLeftBack",
        "wheelRightBack",
        "Stativ_vis",
    },
)
