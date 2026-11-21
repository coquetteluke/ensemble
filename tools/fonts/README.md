# Fonts

Ensemble ships three fonts, all under the SIL Open Font License 1.1. Licence texts sit next to the font
files in `Packages/EnsembleKit/Sources/EnsembleKit/Resources/Fonts/`. A test (`onlyTheListedFontFilesAreBundled`)
fails when a file that is not on this list appears in that folder.

| Font | Used for | Source |
|---|---|---|
| Inter (`InterVariable.ttf`) | Interface text by default, and a choice for the chat font | github.com/rsms/inter, unmodified |
| Ensemble Serif (`EnsembleSerif.ttf`, `EnsembleSerif-Italic.ttf`) | What agents write, by default | Built from Roboto Serif (github.com/google/fonts, `ofl/robotoserif`) |
| Source Serif 4 (`SourceSerif4.ttf`, `SourceSerif4-Italic.ttf`) | A choice for either font | Adobe, github.com/google/fonts `ofl/sourceserif4`, unmodified |

## Choosing fonts

Two fonts are chosen in Settings (Mac: General, Fonts; iPhone: Settings, Fonts): the chat font, for what
agents write, and the interface font, for everything else. Code stays in the system's fixed-width font. The
list is `AppFont.builtIn` in `Packages/EnsembleKit/Sources/EnsembleKit/UI/AppFont.swift`:

- Bundled: Ensemble Serif (the default chat font), Source Serif 4, Inter (the default interface font).
- System fonts, used by name with no file in the app: New York (system serif), San Francisco (system sans),
  Charter, Iowan Old Style, Georgia, Palatino, Avenir Next. A font a system lacks is left out.
- Fonts the owner adds with "Add Font" (`.ttf` and `.otf`). They are copied to
  `Application Support/Ensemble/Fonts` on that device (`CustomFontLibrary`) and registered for the running
  app only. They never enter the repository or a build. Do not add such a file here.

The choices and the added fonts sync between the owner's paired Mac and iPhone while the two are connected
(`FontSync` in `Remote/RemoteFonts.swift`): the newer choice wins on both, added font files are copied across
in pieces inside the encrypted connection, and a font removed on one device is removed on the other.

Only bundle a font whose licence allows it (SIL OFL or similar), with its licence text next to the file.

## Source Serif 4

Adobe's original variable fonts, unchanged: `SourceSerif4[opsz,wght].ttf` and `SourceSerif4-Italic[opsz,wght].ttf`
from `ofl/sourceserif4`, stored here under shorter file names. "Source" is a Reserved Font Name under the SIL
Open Font License 1.1, so only unchanged files may be called Source Serif 4. Do not instance, subset or rename
them: `sourceSerifFilesAreAdobesOriginals` compares the files with the upstream git blob ids
(`40bbb58c...` and `ccb969aa...`) and fails on any change. The font keeps its optical size axis, so the system
picks the cut for the size it is drawn at.

An earlier build (commit `52ed247`, optical size pinned to 20 and a heavier weight curve) shipped renamed as
"Ensemble Serif" and is no longer in the app.

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
