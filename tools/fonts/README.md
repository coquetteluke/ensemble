# Fonts

Ensemble ships three fonts, all under the SIL Open Font License 1.1. Licence texts sit next to the font
files in `Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/`. A test (`onlyTheListedFontFilesAreBundled`)
fails when a file that is not on this list appears in that folder.

| Font | Used for | Source |
|---|---|---|
| Inter (`InterVariable.ttf`) | Interface text, and a chat font choice | github.com/rsms/inter, unmodified |
| Ensemble Serif 4 (`EnsembleSerif4.ttf`, `EnsembleSerif4-Italic.ttf`) | What agents write, by default | Built from Adobe Source Serif 4 (github.com/google/fonts, `ofl/sourceserif4`) |
| Ensemble Serif (`EnsembleSerif.ttf`, `EnsembleSerif-Italic.ttf`) | A chat font choice | Built from Roboto Serif (github.com/google/fonts, `ofl/robotoserif`) |

## Chat font

The font agents write in is chosen in Settings (Mac: General, iPhone: Settings, Chat font). The list is
`ChatFont.builtIn` in `Packages/EnsembleKit/Sources/EnsembleKit/UI/ChatFont.swift`:

- Bundled: Ensemble Serif 4 (default), Ensemble Serif, Inter.
- System fonts, used by name with no file in the app: New York (system serif), San Francisco (system sans),
  Charter, Iowan Old Style, Georgia, Palatino, Avenir Next. A font a system lacks is left out.
- Fonts the owner adds with "Add Font" (`.ttf` and `.otf`). They are copied to
  `Application Support/Ensemble/Fonts` on that device (`CustomFontLibrary`), registered for the running app
  only, and never enter the repository, a build or the remote protocol. Do not add such a file here.

Only bundle a font whose licence allows it (SIL OFL or similar), with its licence text next to the file.

## Ensemble Serif 4

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

"Source" is a Reserved Font Name under the SIL Open Font License 1.1, so a modified copy may not carry it.
The font is named "Ensemble Serif 4" throughout (keeping the required copyright notice in `nameID 0`), and
Settings shows "Built from Source Serif 4" under the name. Both Regular and Italic carry matching `STAT`,
`OS/2`, and `head` flags so CoreText and SwiftUI pick the true italic and bold cuts without synthetic fallback.

The files in the repository are the build of commit `52ed247` (then called "Ensemble Serif"), renamed with
`tools/fonts/rename-family.py`, which changes only the `name` table and needs nothing installed:

```bash
python3 tools/fonts/rename-family.py old/EnsembleSerif.ttf Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/EnsembleSerif4.ttf "Ensemble Serif" "Ensemble Serif 4"
python3 tools/fonts/rename-family.py old/EnsembleSerif-Italic.ttf Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/EnsembleSerif4-Italic.ttf "Ensemble Serif" "Ensemble Serif 4"
```

Rebuild from Source Serif 4 itself (needs `pip install fonttools`):

```bash
python3 tools/fonts/build-ensemble-serif-4.py "SourceSerif4[opsz,wght].ttf" Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/EnsembleSerif4.ttf Regular
python3 tools/fonts/build-ensemble-serif-4.py "SourceSerif4-Italic[opsz,wght].ttf" Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/EnsembleSerif4-Italic.ttf Italic
```

## Ensemble Serif

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
