import os

block = (
    "\n"
    "    <!-- ========== HELP LINE (sprayer) ========== -->\n"
    '    <text name="helpLine_cs_t3_title"          text="Sprayers &amp; Watering"/>\n'
    '    <text name="helpLine_cs_t3_sprayer_title"  text="Using Sprayers as Irrigation"/>\n'
    '    <text name="helpLine_cs_t3_sprayer_text"   text="Standard vehicle-based sprayers can be used as a manual alternative to permanent irrigation systems. If you fill a sprayer with WATER, any area you spray will receive an immediate moisture boost. This is useful for small fields or as a temporary measure until you can afford a centre pivot or drip line."/>\n'
)

base = os.path.join(os.path.dirname(__file__), "..", "translations")
langs = ["fr", "it", "pl"]

for lang in langs:
    path = os.path.join(base, "translation_%s.xml" % lang)
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    if "helpLine_cs_t3_title" in content:
        print("%s: already up to date" % lang)
        continue
    if "</texts>" in content:
        content = content.replace("</texts>", block + "    </texts>")
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        print("%s: updated OK" % lang)
    else:
        print("%s: WARNING - </texts> not found" % lang)
