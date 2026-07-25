# Documentation brand assets

This file maps the future nobsprompt logo package to stable website paths.
Keep the filenames below when replacing the current placeholder so the site
configuration and metadata remain predictable.

## Asset map

| Purpose | Target path | Format and guidance | Wiring |
| --- | --- | --- | --- |
| Header mark | `public/logo.svg` | Transparent SVG with a tight viewBox and good contrast at 24 px | Set `logo.image` in `blume.config.ts` |
| Browser favicon | `public/icon.svg` | Square SVG that remains legible at 16 px | Auto-detected by Blume |
| Apple touch icon | `public/apple-touch-icon.png` | 180 by 180 px PNG with an opaque background | Auto-detected by Blume |
| Social card mark | `public/og-logo.svg` | Simple transparent SVG suitable for a 1200 by 630 px card | Set `seo.og.logo` in `blume.config.ts` |

The existing `public/icon.svg` is a temporary placeholder. Replace it only
when the final mark is ready.

## Header configuration

After adding `public/logo.svg`, configure the header without baking the project
name into the image:

```ts
logo: {
  image: {
    light: "/logo.svg",
    dark: "/logo.svg",
    alt: "nobsprompt",
  },
  text: "nobsprompt",
},
```

If the logo needs separate light and dark artwork, save the variants as
`public/logo-light.svg` and `public/logo-dark.svg`, then update the two paths.

## Social card configuration

After adding `public/og-logo.svg`, extend the existing Open Graph settings:

```ts
seo: {
  og: {
    enabled: true,
    logo: "/og-logo.svg",
  },
},
```

Blume will continue generating a 1200 by 630 px card for every documentation
page. The logo file is only the mark placed within those cards.

## Replacement checklist

1. Add the final files under `public/` using the paths in the map.
2. Add the header and Open Graph configuration only after their files exist.
3. Run `pnpm run docs:ci`.
4. Inspect the header in light and dark modes.
5. Inspect one generated file under `dist/og/`.
6. Confirm the favicon and Apple touch icon tags in `dist/index.html`.
