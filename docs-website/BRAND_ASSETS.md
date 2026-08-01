# Documentation brand assets

The editable source of the nobsprompt mark is
`assets/nobsprompt.svg`. Its background is transparent. The foreground follows
the system color scheme when loaded as an image and the Blume theme when
inlined in the documentation header.

## Asset map

| Purpose | Generated path | Notes |
| --- | --- | --- |
| Header and Open Graph mark | `public/logo.svg` | Adaptive transparent SVG inlined by Blume in the header and used in generated social cards |
| Browser favicon | `public/icon.svg` | Byte-identical to `logo.svg` and auto-detected by Blume |
| GitHub light-theme mark | `public/logo-light.svg` | Static near-black foreground for README `<picture>` fallback and light mode |
| GitHub dark-theme mark | `public/logo-dark.svg` | Static white foreground for README dark mode |
| Apple touch icon | `public/apple-touch-icon.png` | Opaque 180 by 180 px PNG, auto-detected by Blume |

The source view box is 2048 by 2048. The paths are fitted to all four edges
instead of carrying internal canvas padding. The foreground and green paths
share one preserved transform. The foreground stops beneath the green cap's
outer edges and slightly overprints their internal color boundary, preventing
dark outer fringes or light seams when the vector is rasterized at small sizes.

## Updating the logo

1. Edit `assets/nobsprompt.svg`.
2. Keep the 2048 by 2048 view box, transparent background, adaptive foreground
   rules, and shared path transform.
3. Generate optimized public assets:

   ```sh
   pnpm run brand:build
   ```

4. Validate the assets and the complete static site:

   ```sh
   pnpm run docs:ci
   ```

`brand:check` is part of the CI command. SVG variants are compared byte for
byte. The Apple touch icon is decoded and checked for PNG format, 180 by 180
dimensions, opacity, and visual equivalence. This keeps stale-image detection
without depending on platform-specific PNG compression or edge rasterization.

## Website wiring

- `blume.config.ts` assigns `public/logo.svg` to the site header and generated
  Open Graph cards.
- `components/Logo.astro` renders the 24 px mobile and 32 px desktop mark,
  project name, and author credit without client-side JavaScript.
- Blume discovers `icon.svg` and `apple-touch-icon.png` automatically.
- The README uses GitHub's supported `<picture>` pattern to select the static
  light or dark variant.
