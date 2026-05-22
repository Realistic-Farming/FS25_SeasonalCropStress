import os

block = (
    "\n"
    "    <!-- ========== HELP DIALOG ========== -->\n"
    '    <text name="cs_help_title"       text="Crop Moisture Monitor -- Help"/>\n'
    '    <text name="cs_help_ov_hdr"      text="How It Works"/>\n'
    '    <text name="cs_help_ov_1"        text="Tracks soil moisture for every field in the game."/>\n'
    '    <text name="cs_help_ov_2"        text="Rainfall raises moisture; heat and time reduce it."/>\n'
    '    <text name="cs_help_ov_3"        text="Use the filter button to focus on your own fields."/>\n'
    '    <text name="cs_help_status_hdr"  text="Moisture Levels"/>\n'
    '    <text name="cs_help_status_1"    text="Healthy  &gt;=40%   No action needed."/>\n'
    '    <text name="cs_help_status_2"    text="Warning  25-40%  Irrigate soon."/>\n'
    '    <text name="cs_help_status_3"    text="Critical &lt;25%   Irrigate now!"/>\n'
    '    <text name="cs_help_stress_hdr"  text="Crop Stress"/>\n'
    '    <text name="cs_help_stress_1"    text="Builds each hour moisture stays below 40% during growth."/>\n'
    '    <text name="cs_help_stress_2"    text="Up to 60% yield loss at max stress. Cannot be reversed."/>\n'
    '    <text name="cs_help_irr_hdr"     text="Irrigation"/>\n'
    '    <text name="cs_help_irr_1"       text="Place Center Pivots or Drip Lines from the build menu."/>\n'
    '    <text name="cs_help_irr_2"       text="Use Irrigation Schedule to set automatic run windows."/>\n'
    '    <text name="cs_help_keys_hdr"    text="Monitor Information"/>\n'
    '    <text name="cs_help_keys_1"      text="ESC (Pause Menu) -&gt; Crop Moisture Monitor"/>\n'
    '    <text name="cs_help_keys_2"      text="Tab 1 (Overview) -&gt;  Overall field status"/>\n'
    '    <text name="cs_help_keys_3"      text="Tab 2 (Irrigation) -&gt;  Irrigation management"/>\n'
    "    <!-- ========== PDA SCREEN ========== -->\n"
    '    <text name="cs_pda_btn_irrigation"         text="Irrigation Schedule"/>\n'
    '    <text name="cs_pda_btn_consultant"         text="Crop Consultant"/>\n'
    '    <text name="cs_pda_btn_help"               text="Help"/>\n'
    '    <text name="cs_pda_filter_all"             text="ALL FIELDS"/>\n'
    '    <text name="cs_pda_filter_owned"           text="MY FIELDS"/>\n'
    '    <text name="cs_pda_no_system_msg"          text="No irrigation system is connected to this field. Place a center pivot or drip line to manage irrigation."/>\n'
)

base = os.path.join(os.path.dirname(__file__), "..", "translations")
langs = ["cz", "de", "fr", "it", "nl", "pl", "uk"]

for lang in langs:
    path = os.path.join(base, "translation_%s.xml" % lang)
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    if "cs_help_title" in content:
        print("%s: already up to date" % lang)
        continue
    if "</texts>" in content:
        content = content.replace("</texts>", block + "    </texts>")
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        print("%s: updated OK" % lang)
    else:
        print("%s: WARNING - </texts> not found" % lang)
