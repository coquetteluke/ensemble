"""Builds Ensemble Serif from Source Serif 4 (SIL OFL 1.1), Option C3.

Changes from Source Serif 4:
- Optical size pinned to opsz = 20.0.
- Weight axis spans user weights 300..900 (default 400), remapped through a composed avar curve
  onto Source Serif 4 design weights tuned for dark-mode clarity:
  300 -> 300, 400 -> 430, 500 -> 520, 600 -> 630, 700 -> 740, 800 -> 820, 900 -> 900.
- Builds either Regular (from SourceSerif4[opsz,wght].ttf) or Italic (from
  SourceSerif4-Italic[opsz,wght].ttf), with matching STAT, OS/2, head, and name records so
  CoreText and SwiftUI resolve bold, italic, and bold-italic without synthetic fallback.
- Renamed to "Ensemble Serif" throughout (except the required copyright notice in nameID 0),
  since "Source" is a Reserved Font Name under the SIL Open Font License 1.1.
"""
import sys
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools.varLib.models import piecewiseLinearMap
from fontTools.ttLib.tables._a_v_a_r import table__a_v_a_r
from fontTools.ttLib.tables._f_v_a_r import NamedInstance

WEIGHTS = {
    300: "Light",
    400: "Regular",
    500: "Medium",
    600: "SemiBold",
    700: "Bold",
    800: "ExtraBold",
    900: "Black",
}

OPTICAL_SIZE = 20.0
MIN_WEIGHT, DEFAULT_DESIGN_WEIGHT, MAX_WEIGHT = 300.0, 430.0, 900.0

# User weight -> Source Serif 4 design weight at opsz = 20 (Option C3).
WEIGHT_CURVE = [
    (300.0, 300.0),
    (400.0, 430.0),
    (500.0, 520.0),
    (600.0, 630.0),
    (700.0, 740.0),
    (800.0, 820.0),
    (900.0, 900.0),
]


def interp_linear(pairs, x):
    """Piecewise-linear interpolation over sorted (x, y) pairs."""
    for (x0, y0), (x1, y1) in zip(pairs, pairs[1:]):
        if x <= x1:
            t = (x - x0) / (x1 - x0)
            return y0 + t * (y1 - y0)
    return pairs[-1][1]


def build_composed_avar(existing_seg):
    """Compose user->design WEIGHT_CURVE with Source Serif 4's internal avar segment."""
    def u_to_xu(u):
        return (u - 400.0) / (400.0 - MIN_WEIGHT) if u <= 400.0 else (u - 400.0) / (MAX_WEIGHT - 400.0)

    def d_to_xd(d):
        if d <= DEFAULT_DESIGN_WEIGHT:
            return (d - DEFAULT_DESIGN_WEIGHT) / (DEFAULT_DESIGN_WEIGHT - MIN_WEIGHT)
        return (d - DEFAULT_DESIGN_WEIGHT) / (MAX_WEIGHT - DEFAULT_DESIGN_WEIGHT)

    def xd_to_d(xd):
        if xd <= 0.0:
            return DEFAULT_DESIGN_WEIGHT + xd * (DEFAULT_DESIGN_WEIGHT - MIN_WEIGHT)
        return DEFAULT_DESIGN_WEIGHT + xd * (MAX_WEIGHT - DEFAULT_DESIGN_WEIGHT)

    reverse_curve = [(d, u) for u, d in WEIGHT_CURVE]
    u_points = {u for u, _ in WEIGHT_CURVE}
    for xd in existing_seg:
        u_points.add(interp_linear(reverse_curve, xd_to_d(xd)))

    composed = {}
    for u in sorted(u_points):
        xu = round(u_to_xu(u), 6)
        xd = d_to_xd(interp_linear(WEIGHT_CURVE, u))
        composed[xu] = round(piecewiseLinearMap(xd, existing_seg), 6)
    return composed


def add_instances(font, italic):
    """Standard weights as fvar named instances and matching STAT wght names."""
    name, fvar = font["name"], font["fvar"]
    fvar.instances = []
    for weight, label in WEIGHTS.items():
        sub = (label + " Italic").replace("Regular Italic", "Italic") if italic else label
        inst = NamedInstance()
        inst.coordinates = {"wght": float(weight)}
        inst.subfamilyNameID = name.addMultilingualName({"en": sub}, mac=False, minNameID=256)
        inst.postscriptNameID = name.addMultilingualName(
            {"en": "EnsembleSerif-" + sub.replace(" ", "")}, mac=False, minNameID=256
        )
        fvar.instances.append(inst)
    if "STAT" in font and font["STAT"].table.AxisValueArray:
        tags = [a.AxisTag for a in font["STAT"].table.DesignAxisRecord.Axis]
        for value in font["STAT"].table.AxisValueArray.AxisValue:
            index = getattr(value, "AxisIndex", None)
            if index is not None and tags[index] == "wght" and int(value.Value) in WEIGHTS:
                value.ValueNameID = name.addMultilingualName(
                    {"en": WEIGHTS[int(value.Value)]}, mac=False, minNameID=256
                )


def referenced_high_name_ids(font):
    """Collect nameIDs >= 256 referenced by fvar, STAT, GSUB, or GPOS."""
    used = set()
    if "fvar" in font:
        for axis in font["fvar"].axes:
            used.add(axis.axisNameID)
        for inst in font["fvar"].instances:
            used.add(inst.subfamilyNameID)
            if inst.postscriptNameID != 0xFFFF:
                used.add(inst.postscriptNameID)
    if "STAT" in font:
        stat = font["STAT"].table
        used.add(stat.ElidedFallbackNameID)
        if stat.DesignAxisRecord:
            for axis in stat.DesignAxisRecord.Axis:
                used.add(axis.AxisNameID)
        if stat.AxisValueArray:
            for val in stat.AxisValueArray.AxisValue:
                used.add(val.ValueNameID)
    for tag in ("GSUB", "GPOS"):
        if tag in font and font[tag].table.FeatureList:
            for rec in font[tag].table.FeatureList.FeatureRecord:
                fp = rec.Feature.FeatureParams
                if fp:
                    for attr in (
                        "UINameID",
                        "FeatUILabelNameID",
                        "FeatUITooltipTextNameID",
                        "SampleTextNameID",
                        "FirstParamUILabelNameID",
                    ):
                        if hasattr(fp, attr):
                            used.add(getattr(fp, attr))
    return {nid for nid in used if nid >= 256}


def build(src, out, style):
    if style not in ("Regular", "Italic"):
        raise SystemExit(f"Unsupported style {style!r}; expected 'Regular' or 'Italic'")

    italic = style == "Italic"
    font = TTFont(src)
    font = instancer.instantiateVariableFont(
        font,
        {"opsz": OPTICAL_SIZE, "wght": (MIN_WEIGHT, DEFAULT_DESIGN_WEIGHT, MAX_WEIGHT)},
        updateFontNames=False,
    )

    existing_seg = dict(font["avar"].segments.get("wght", {-1.0: -1.0, 0.0: 0.0, 1.0: 1.0}))

    fvar = font["fvar"]
    wght = next(a for a in fvar.axes if a.axisTag == "wght")
    wght.minValue, wght.defaultValue, wght.maxValue = 300.0, 400.0, 900.0

    avar = font["avar"] if "avar" in font else table__a_v_a_r()
    font["avar"] = avar
    avar.segments = {"wght": build_composed_avar(existing_seg)}

    add_instances(font, italic)

    name = font["name"]
    family = "Ensemble Serif"
    sub = "Italic" if italic else "Regular"
    ps = "EnsembleSerif-" + sub
    ps_prefix = "EnsembleSerifItalic" if italic else "EnsembleSerifRoman"
    copyright_old = name.getDebugName(0) or ""
    records = {
        0: copyright_old + " Ensemble Serif is a modified version made for Ensemble in 2026.",
        1: family,
        2: sub,
        3: f"2026;ENSEMBLE;{ps}",
        4: f"{family} {sub}",
        5: "Version 1.000; optical size 20, dark-mode weight curve",
        6: ps,
        16: family,
        17: sub,
        25: ps_prefix,
    }
    for rec in list(name.names):
        if rec.nameID in (7, 8, 11, 12, 18, 21, 22) or rec.nameID in records:
            name.removeNames(nameID=rec.nameID)
    for nid, value in records.items():
        name.setName(value, nid, 3, 1, 0x409)
        name.setName(value, nid, 1, 0, 0)

    keep_high = referenced_high_name_ids(font)
    for rec in list(name.names):
        if rec.nameID >= 256 and rec.nameID not in keep_high:
            name.removeNames(nameID=rec.nameID)

    # No trace of the reserved name may remain outside the copyright record (nameID 0).
    for rec in name.names:
        if rec.nameID == 0:
            continue
        text = rec.toUnicode()
        for old, new in [
            ("Source Serif 4", "Ensemble Serif"),
            ("SourceSerif4Roman", "EnsembleSerifRoman"),
            ("SourceSerif4Italic", "EnsembleSerifItalic"),
            ("SourceSerif4", "EnsembleSerif"),
        ]:
            if old in text:
                text = text.replace(old, new)
        rec.string = text

    os2 = font["OS/2"]
    os2.usWeightClass = 400
    os2.usWidthClass = 5
    if italic:
        os2.fsSelection = (os2.fsSelection | 0x01) & ~0x40 & ~0x20
        font["head"].macStyle = (font["head"].macStyle | 0x02) & ~0x01
    else:
        os2.fsSelection = (os2.fsSelection | 0x40) & ~0x01 & ~0x20
        font["head"].macStyle &= ~(0x01 | 0x02)

    font.save(out)
    leftover = [
        (r.nameID, r.toUnicode())
        for r in font["name"].names
        if r.nameID != 0 and any(w in r.toUnicode().lower() for w in ("source", "adobe", "merriweather"))
    ]
    if leftover:
        raise RuntimeError(f"Reserved font name remains in name table: {leftover}")
    print("saved", out, "axes", [(a.axisTag, a.minValue, a.defaultValue, a.maxValue) for a in font["fvar"].axes], "leftover", leftover)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: build-ensemble-serif.py <src.ttf> <out.ttf> <Regular|Italic>")
    build(sys.argv[1], sys.argv[2], sys.argv[3])
