"""Builds Ensemble Serif from Merriweather (SIL OFL 1.1).

Changes from Merriweather: width fixed at its normal 100, weight axis relabelled so the
standard weights land where they read like the reference app's text (Regular 400 is
Merriweather 325, Medium 500 is 480, SemiBold 600 is 650, Bold 700 is 720, a touch heavier
than the reference's bold), and every name changed, since "Merriweather" is a Reserved Font
Name under its licence.
"""
import sys
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools.ttLib.tables._a_v_a_r import table__a_v_a_r

from fontTools.ttLib.tables._f_v_a_r import NamedInstance

WEIGHTS = {300: "Light", 400: "Regular", 500: "Medium", 600: "SemiBold", 700: "Bold", 800: "ExtraBold", 900: "Black"}


def add_instances(font, italic):
    """Standard weights as named instances, and matching names in the style table."""
    name, fvar = font["name"], font["fvar"]
    opsz = next((a.defaultValue for a in fvar.axes if a.axisTag == "opsz"), None)
    fvar.instances = []
    for weight, label in WEIGHTS.items():
        sub = (label + " Italic").replace("Regular Italic", "Italic") if italic else label
        inst = NamedInstance()
        inst.coordinates = {"wght": float(weight)} | ({"opsz": opsz} if opsz is not None else {})
        inst.subfamilyNameID = name.addMultilingualName({"en": sub}, mac=False, minNameID=256)
        inst.postscriptNameID = name.addMultilingualName({"en": "EnsembleSerif-" + sub.replace(" ", "")}, mac=False, minNameID=256)
        fvar.instances.append(inst)
    if "STAT" in font and font["STAT"].table.AxisValueArray:
        tags = [a.AxisTag for a in font["STAT"].table.DesignAxisRecord.Axis]
        for value in font["STAT"].table.AxisValueArray.AxisValue:
            index = getattr(value, "AxisIndex", None)
            if index is not None and tags[index] == "wght" and int(value.Value) in WEIGHTS:
                value.ValueNameID = name.addMultilingualName({"en": WEIGHTS[int(value.Value)]}, mac=False, minNameID=256)


if __name__ != "__main__":
    raise SystemExit

src, out, style = sys.argv[1], sys.argv[2], sys.argv[3]  # style: "Regular" or "Italic"
font = TTFont(src)
WIDTH, DEFAULT, MAX = 100, 325, 900
font = instancer.instantiateVariableFont(font, {"wdth": WIDTH, "wght": (300, DEFAULT, MAX)}, updateFontNames=False)

# Relabel the weight axis: the new default (design DEFAULT) is user weight 400.
fvar = font["fvar"]
wght = next(a for a in fvar.axes if a.axisTag == "wght")
wght.minValue, wght.defaultValue, wght.maxValue = 300.0, 400.0, 900.0

# User weight to design weight. Normalised: user (u-400)/500 above the default; design
# (d-DEFAULT)/(MAX-DEFAULT) above. Below the default both run linearly to 300.
def up_user(u): return (u - 400) / 500
def up_design(d): return (d - DEFAULT) / (MAX - DEFAULT)
mapping = {-1.0: -1.0, 0.0: 0.0}
for user, design in [(500, 480), (600, 650), (700, 720)]:
    mapping[up_user(user)] = up_design(design)
mapping[1.0] = 1.0
if "avar" in font:
    avar = font["avar"]
else:
    avar = table__a_v_a_r(); font["avar"] = avar
avar.segments = {a.axisTag: ({-1.0: -1.0, 0.0: 0.0, 1.0: 1.0} if a.axisTag != "wght" else dict(sorted(mapping.items()))) for a in fvar.axes}

# Named instances. Pinning the width drops Merriweather's own (they sit at width 100), so the
# standard weights are added back at their user values, named for Ensemble Serif.
name = font["name"]
italic = style == "Italic"
add_instances(font, italic)

family = "Ensemble Serif"
sub = "Italic" if italic else "Regular"
ps = "EnsembleSerif-" + sub
copyright_old = name.getDebugName(0) or ""
records = {
    0: copyright_old + " Ensemble Serif is a modified version made for Ensemble in 2026.",
    1: family, 2: sub, 3: f"2026;ENSEMBLE;{ps}", 4: f"{family} {sub}".replace(" Regular", " Regular"),
    5: "Version 1.000; based on Merriweather", 6: ps, 16: family, 17: sub, 25: "EnsembleSerif",
}
for rec in list(name.names):
    if rec.nameID in (7, 8, 11, 12, 18, 21, 22) or rec.nameID in records:
        name.removeNames(nameID=rec.nameID)
for nid, value in records.items():
    name.setName(value, nid, 3, 1, 0x409)
    name.setName(value, nid, 1, 0, 0)
# No trace of the reserved name may remain in any name record.
for rec in name.names:
    text = rec.toUnicode()
    if "Merriweather" in text and rec.nameID not in (0, 5):
        rec.string = text.replace("Merriweather", "Ensemble Serif")

os2 = font["OS/2"]
os2.usWeightClass = 400
os2.usWidthClass = 5  # normal width
if italic:
    os2.fsSelection = (os2.fsSelection | 0x01) & ~0x40 & ~0x20
    font["head"].macStyle |= 0x02
else:
    os2.fsSelection = (os2.fsSelection | 0x40) & ~0x01 & ~0x20
    font["head"].macStyle &= ~0x02

font.save(out)
left = [r.toUnicode() for r in font["name"].names if "Merriweather" in r.toUnicode() and r.nameID not in (0, 5)]
print("saved", out, "axes", [(a.axisTag, a.minValue, a.defaultValue, a.maxValue) for a in font["fvar"].axes], "leftover names", left)
