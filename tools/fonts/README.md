# Fonts

Ensemble ships two fonts, both under the SIL Open Font License 1.1. Licence texts sit next to the font
files in `Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/`.

| Font | Used for | Source |
|---|---|---|
| Inter (`InterVariable.ttf`) | Interface text | github.com/rsms/inter, unmodified |
| Ensemble Serif (`EnsembleSerif.ttf`) | What agents write | Built from Merriweather (github.com/google/fonts, `ofl/merriweather`) |

## Ensemble Serif

Merriweather at its normal width. Regular is Merriweather's own Regular (400); the weight axis is
remapped above it, so SemiBold reads like the serif in the reference app and Bold is a touch heavier. A
lighter Regular (325) was tried first and read as blurry on dark backgrounds (matched by measuring x-height, ink per line and line
length, never by copying another font's data). "Merriweather" is a Reserved Font Name, so the result
is renamed throughout.

Rebuild (needs `pip install fonttools`):

```bash
python3 tools/fonts/build-ensemble-serif.py "Merriweather[opsz,wdth,wght].ttf" EnsembleSerif.ttf Regular
```
