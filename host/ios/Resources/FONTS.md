# Fonts bundled with openbirds

All five typefaces are distributed under the **SIL Open Font License 1.1**.
Per the OFL, redistribution (including embedding in this iOS bundle) is
permitted; the OFL text is reproduced in `OFL.txt` alongside this file.
Per-font copyright notices and upstream sources:

## EBGaramond-Regular.ttf

- **Designer:** Georg Mayr-Duffner; expanded by Octavio Pardo (& contributors)
- **Source:** https://github.com/octaviopardo/EBGaramond12 (`fonts/ttf/EBGaramond12-Regular.ttf`)
- **Copyright:** Copyright 2017 The EB Garamond Project Authors
- **Vendored via:** nixpkgs `eb-garamond-0.016`, file
  `share/fonts/truetype/EBGaramond12-Regular.ttf`, renamed for brevity.

## CormorantGaramond-Regular.ttf

- **Designer:** Christian Thalmann (Catharsis Fonts), 2015
- **Source:** https://raw.githubusercontent.com/CatharsisFonts/Cormorant/master/fonts/ttf/CormorantGaramond-Regular.ttf
- **Copyright:** Copyright 2015 Christian Thalmann (catharsisfonts.com)
- **SHA256:** 6692a7e7f324e71ec0be0c36d1aab340dbf1df0ce2e29ab1770082f28e45eb09

## Jost-Medium.ttf

- **Designer:** Owen Earl (Indestructible Type Foundry), 2017
- **Source:** https://github.com/indestructible-type/Jost (`Jost/static/Jost-500-Medium.ttf`)
- **Copyright:** Copyright 2020 The Jost Project Authors (https://github.com/indestructible-type/Jost)
- **Vendored via:** nixpkgs `jost-3.5`, file
  `share/fonts/truetype/Jost-500-Medium.ttf`, renamed for brevity.

## terminal-grotesque.ttf

- **Designer:** Raphaël Bastide / Jérémy Landes (Velvetyne Type Foundry / Studio Triple)
- **Source:** https://raw.githubusercontent.com/StudioTriple/Terminal-Grotesque/master/terminal-grotesque.ttf
- **License header in source repo references "Blackout" (Tyler Finck);** that is the
  OFL boilerplate the Velvetyne author started from. The license body is genuinely
  SIL OFL 1.1; the actual attribution lives in the repo's `METADATA.yml`.
- **SHA256:** 89cb77fe1be6f31e90b702e2b5536c6878cda0d244ec961b73e54bf1557256d3

## TerminusTTF.ttf

- **Designer:** Dimitar Zhekov, 2002–present
- **Source:** https://files.ax86.net/terminus-ttf/  (TerminusTTF distribution; original
  Terminus is bitmap, the TTF wrapper preserves the exact pixel grid at the supported
  sizes)
- **Vendored via:** nixpkgs `terminus-font-ttf-4.49.3`, file
  `share/fonts/truetype/TerminusTTF.ttf`.
- **Original Terminus** by Dimitar Zhekov is in the public domain; the TTF wrapper is
  released under SIL OFL 1.1.
