import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { optimize } from "svgo";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sourcePath = resolve(projectRoot, "assets/nobsprompt.svg");
const publicDirectory = resolve(projectRoot, "public");
const mode = process.argv[2];

if (mode !== "--check" && mode !== "--write") {
  console.error("Usage: node scripts/brand-assets.mjs --check|--write");
  process.exit(2);
}

const source = await readFile(sourcePath, "utf8");

if (
  !source.includes('class="nbsp-foreground"') ||
  !source.includes("@media (prefers-color-scheme: dark)") ||
  !source.includes(':root[data-theme="dark"]')
) {
  throw new Error(
    "The source logo must contain adaptive foreground color rules."
  );
}

if (/<rect\b/u.test(source)) {
  throw new Error("The source logo must have a transparent background.");
}

if (/<path\b[^>]*\bstroke=/u.test(source)) {
  throw new Error("The source logo paths must preserve their original widths.");
}

if (
  /<metadata\b|preserveAspectRatio="none"|style="display:\s*block"/u.test(
    source
  )
) {
  throw new Error("The source logo still contains removable generator markup.");
}

const optimizeLogo = (content) => {
  const optimized = optimize(content, {
    multipass: true,
    path: sourcePath,
    plugins: [
      "removeDoctype",
      "removeXMLProcInst",
      "removeComments",
      "removeMetadata",
      "minifyStyles",
      "removeDimensions",
      "sortAttrs",
    ],
  });

  if (optimized.error) {
    throw new Error(optimized.error);
  }

  return Buffer.from(`${optimized.data.trim()}\n`);
};

const staticLogo = (foreground) =>
  optimizeLogo(
    source
      .replace(/<style\b[^>]*>[\s\S]*?<\/style>/u, "")
      .replace('class="nbsp-foreground"', `fill="${foreground}"`)
  );

const logo = optimizeLogo(source);
const logoLight = staticLogo("#191919");
const logoDark = staticLogo("#fff");
const logoText = logo.toString();

if (!/<svg\b[^>]*\bviewBox="0 0 2048 2048"/u.test(logoText)) {
  throw new Error("The optimized logo lost its view box.");
}

if (
  !/prefers-color-scheme:\s*dark/u.test(logoText) ||
  !logoText.includes("data-theme=dark") ||
  !/<g\b[^>]*\btransform="matrix\(/u.test(logoText) ||
  logoText.includes("&quot;") ||
  /<path\b[^>]*\bstroke=/u.test(logoText) ||
  /<rect\b/u.test(logoText)
) {
  throw new Error("The optimized logo lost its adaptive transparent styling.");
}

const appleTouchIcon = await sharp(logoLight)
  .resize(180, 180, { fit: "contain" })
  .flatten({ background: "#ffffff" })
  .png({ compressionLevel: 9, palette: true })
  .toBuffer();

const assets = new Map([
  ["logo.svg", logo],
  ["icon.svg", logo],
  ["logo-light.svg", logoLight],
  ["logo-dark.svg", logoDark],
  ["apple-touch-icon.png", appleTouchIcon],
]);

if (mode === "--write") {
  await mkdir(publicDirectory, { recursive: true });
  await Promise.all(
    [...assets].map(([name, content]) =>
      writeFile(resolve(publicDirectory, name), content)
    )
  );
  console.log(
    "Generated adaptive, light, dark, favicon, and Apple touch assets."
  );
  process.exit(0);
}

const stale = [];

for (const [name, expected] of assets) {
  try {
    const actual = await readFile(resolve(publicDirectory, name));
    if (!actual.equals(expected)) {
      stale.push(name);
    }
  } catch {
    stale.push(name);
  }
}

if (stale.length > 0) {
  console.error(`Brand assets are missing or stale: ${stale.join(", ")}`);
  console.error("Run pnpm run brand:build and commit the generated files.");
  process.exit(1);
}

console.log("Brand assets match the canonical SVG source.");
