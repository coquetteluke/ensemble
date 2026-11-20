# Fonts

Ensemble ships two fonts, both under the SIL Open Font License 1.1. Licence texts sit next to the font
files in `Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/`.

| Font | Used for | Source |
|---|---|---|
| Inter (`InterVariable.ttf`) | Interface text | github.com/rsms/inter, unmodified |
| Ensemble Serif (`EnsembleSerif.ttf`, `EnsembleSerif-Italic.ttf`) | What agents write | Built from Adobe Source Serif 4 (github.com/google/fonts, `ofl/sourceserif4`) |

## Ensemble Serif (Option C3)

Built from Source Serif 4 upright and calligraphic italic variable fonts with optical size pinned to
`opsz = 20`. The `wght` axis spans user weights `300..900` (default `400`), remapped with `avar`
composed over Source Serif 4's internal weight curve for dark-mode clarity:

- `300` (Light) -> design `300`
- `400` (Regular) -> design `430`
- `500` (Medium) -> design `520`
- `600` (SemiBold) -> design `630`
- `700` (Bold) -> design `740`
- `800` (ExtraBold) -> design `820`
- `900` (Black) -> design `900`

"Source" is a Reserved Font Name under the SIL Open Font License 1.1, so the font is renamed to
"Ensemble Serif" throughout (keeping the required copyright notice in `nameID 0`). Both Regular and
Italic carry matching `STAT`, `OS/2`, and `head` flags so CoreText and SwiftUI pick the true
calligraphic italic and dark-mode bold cuts without synthetic fallback.

Rebuild (needs `pip install fonttools`):

```bash
python3 tools/fonts/build-ensemble-serif.py "SourceSerif4[opsz,wght].ttf" Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/EnsembleSerif.ttf Regular
python3 tools/fonts/build-ensemble-serif.py "SourceSerif4-Italic[opsz,wght].ttf" Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/EnsembleSerif-Italic.ttf Italic
```
