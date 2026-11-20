# Fonts

Ensemble ships two fonts, both under the SIL Open Font License 1.1. Licence texts sit next to the font
files in `Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/`.

| Font | Used for | Source |
|---|---|---|
| Inter (`InterVariable.ttf`) | Interface text | github.com/rsms/inter, unmodified |
| Ensemble Serif (`EnsembleSerif.ttf`, `EnsembleSerif-Italic.ttf`) | What agents write | Built from Roboto Serif (github.com/google/fonts, `ofl/robotoserif`) |

## Ensemble Serif (Option C2)

Built from the Roboto Serif upright and italic variable fonts with optical size pinned to `opsz = 14`,
width to `wdth = 100` and grade to `GRAD = 0`. Luke picked this cut on 2026-11-20 from rendered samples
(cleaner, closer to the Gemini and ChatGPT apps, still a serif) and asked for a calmer bold, so the `wght`
axis spans user weights `300..900` (default `400`) through this `avar` curve:

- `300` (Light) -> design `300`
- `400` (Regular) -> design `400`
- `500` (Medium) -> design `470`
- `600` (SemiBold) -> design `520`
- `700` (Bold) -> design `570`
- `800` (ExtraBold) -> design `680`
- `900` (Black) -> design `800`

The font is renamed to "Ensemble Serif" throughout (keeping the copyright notice in `nameID 0`). Roboto
Serif has no Reserved Font Name; the rename keeps it Ensemble's own and avoids clashing with an installed
copy. Regular and Italic carry matching `STAT`, `OS/2`, and `head` flags so CoreText and SwiftUI pick the
true italic and bold cuts without synthetic fallback.

Rebuild (needs `pip install fonttools`):

```bash
python3 tools/fonts/build-ensemble-serif.py "RobotoSerif[GRAD,opsz,wdth,wght].ttf" Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/EnsembleSerif.ttf Regular
python3 tools/fonts/build-ensemble-serif.py "RobotoSerif-Italic[GRAD,opsz,wdth,wght].ttf" Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/EnsembleSerif-Italic.ttf Italic
```
