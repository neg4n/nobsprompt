import { readFileSync, readdirSync, statSync } from "node:fs";
import { relative, resolve } from "node:path";

const site = "https://nobsprompt.pages.dev";
const dist = resolve("dist");
const failures = [];
const videoManifest = JSON.parse(
  readFileSync(resolve("assets/videos/video-manifest.json"), "utf8")
);
const mobileNavigationSource = readFileSync(
  resolve("components/blume/mobile-navigation.ts"),
  "utf8"
);
const landingVideo = videoManifest.assets?.["nobsprompt-demo"];

const fail = (message) => {
  failures.push(message);
};

const read = (path) => readFileSync(resolve(dist, path), "utf8");
const readBuffer = (path) => readFileSync(resolve(dist, path));

const requireFile = (path, minimumBytes = 1) => {
  const absolute = resolve(dist, path);
  try {
    if (statSync(absolute).size < minimumBytes) {
      fail(`${path} is empty or unexpectedly small`);
    }
  } catch {
    fail(`${path} is missing`);
  }
};

const walk = (directory) =>
  readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = resolve(directory, entry.name);
    return entry.isDirectory() ? walk(path) : [path];
  });

const attributes = (tag) => {
  const result = {};
  const expression = /([:\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/gu;
  for (const match of tag.matchAll(expression)) {
    result[match[1].toLowerCase()] = match[2] ?? match[3] ?? "";
  }
  return result;
};

const tags = (html, name) =>
  [...html.matchAll(new RegExp(`<${name}\\b[^>]*>`, "giu"))].map(
    (match) => ({
      raw: match[0],
      attributes: attributes(match[0]),
    })
  );

const decodeAttribute = (value) =>
  value
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replaceAll("&amp;", "&");

const meta = (html, key) => {
  const wanted = key.toLowerCase();
  const tag = tags(html, "meta").find(
    ({ attributes: value }) =>
      value.name?.toLowerCase() === wanted ||
      value.property?.toLowerCase() === wanted
  );
  return tag?.attributes.content ?? "";
};

const normalizeUrl = (value) => {
  const url = new URL(value);
  if (url.pathname === "/") {
    url.pathname = "";
  }
  return url.toString().replace(/\/$/u, "");
};

for (const path of [
  "index.html",
  "robots.txt",
  "sitemap.xml",
  "llms.txt",
  "llms-full.txt",
  "agent-readability.json",
  "index.md",
  "index.mdx",
  "logo.svg",
  "icon.svg",
  "logo-light.svg",
  "logo-dark.svg",
  "apple-touch-icon.png",
  "_headers",
]) {
  requireFile(path, path.startsWith("llms") ? 100 : 1);
}

if (!landingVideo) {
  fail("video-manifest.json is missing nobsprompt-demo");
} else {
  for (const record of [
    ...landingVideo.videos,
    ...landingVideo.posters.avif,
    ...landingVideo.posters.webp,
    landingVideo.posters.jpeg,
  ]) {
    requireFile(record.src.replace(/^\//u, ""), record.bytes);
  }
}

const allFiles = walk(dist);
const compiledCss = allFiles
  .filter((path) => path.endsWith(".css"))
  .map((path) => readFileSync(path, "utf8"))
  .join("\n");
const compiledJavaScript = allFiles
  .filter((path) => path.endsWith(".js"))
  .map((path) => readFileSync(path, "utf8"))
  .join("\n");
const forbidden = allFiles
  .map((path) => relative(dist, path))
  .filter(
    (path) =>
      path === "_worker.js" ||
      path === "_routes.json" ||
      path.startsWith("functions/")
  );

if (forbidden.length > 0) {
  fail(`server artifacts were generated: ${forbidden.join(", ")}`);
}

const htmlFiles = allFiles.filter(
  (path) => path.endsWith(".html") && relative(dist, path) !== "404.html"
);
const canonicalUrls = new Set();

const logo = readBuffer("logo.svg");
const icon = readBuffer("icon.svg");
const logoText = logo.toString("utf8");
const logoLightText = read("logo-light.svg");
const logoDarkText = read("logo-dark.svg");
const appleTouchIcon = readBuffer("apple-touch-icon.png");
const headers = read("_headers");

for (const token of [
  "[data-blume-nav-gesture-zone]",
  "safe-area-inset-right",
  "safe-area-inset-bottom",
  "100dvh",
  "touch-action:pan-y",
  "transform:translate(105%)",
]) {
  if (!compiledCss.includes(token)) {
    fail(`the mobile navigation CSS is missing ${token}`);
  }
}

if (
  !mobileNavigationSource.includes(
    'document.body.style.overflow = "hidden"'
  ) ||
  mobileNavigationSource.includes("root.style.overflow")
) {
  fail("mobile navigation must lock body scrolling without breaking sticky UI");
}

for (const token of [
  "data-blume-nav-dragging",
  "data-blume-nav-closing",
  "pointercancel",
  "visualViewport",
  "blume-mobile-navigation",
]) {
  if (!compiledJavaScript.includes(token)) {
    fail(`the mobile navigation controller is missing ${token}`);
  }
}

if (!logo.equals(icon)) {
  fail("logo.svg and icon.svg are not byte-identical");
}
if (
  !/<svg\b[^>]*\bviewBox="0 0 2048 2048"/u.test(logoText) ||
  !/prefers-color-scheme:\s*dark/u.test(logoText) ||
  !logoText.includes("data-theme=dark") ||
  !/<g\b[^>]*\btransform="matrix\(/u.test(logoText) ||
  logoText.includes("&quot;") ||
  /<path\b[^>]*\bstroke=/u.test(logoText) ||
  /<rect\b/u.test(logoText)
) {
  fail("logo.svg is missing its adaptive transparent styling");
}
if (
  /<style\b|nbsp-foreground/u.test(logoLightText) ||
  !logoLightText.includes('fill="#191919"')
) {
  fail("logo-light.svg is not a static light-theme logo");
}
if (
  /<style\b|nbsp-foreground/u.test(logoDarkText) ||
  !logoDarkText.includes('fill="#fff"')
) {
  fail("logo-dark.svg is not a static dark-theme logo");
}
if (/<metadata\b|transform="translate\(0 0\)"/u.test(logoText)) {
  fail("logo.svg contains removable generator markup");
}
if (
  appleTouchIcon.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a" ||
  appleTouchIcon.readUInt32BE(16) !== 180 ||
  appleTouchIcon.readUInt32BE(20) !== 180
) {
  fail("apple-touch-icon.png is not a 180 by 180 PNG");
}
if (
  !headers.includes("/media/*") ||
  !headers.includes("Cache-Control: public, max-age=31536000, immutable")
) {
  fail("_headers is missing immutable media caching");
}
for (const type of [
  "text/markdown; charset=utf-8",
  "text/plain; charset=utf-8",
]) {
  if (!headers.includes(type)) {
    fail(`_headers is missing ${type}`);
  }
}

for (const path of htmlFiles) {
  const name = relative(dist, path);
  const html = readFileSync(path, "utf8");
  const title = html.match(/<title>([\s\S]*?)<\/title>/iu)?.[1].trim() ?? "";
  const canonicalTag = tags(html, "link").find(
    ({ attributes: value }) => value.rel?.toLowerCase() === "canonical"
  );
  const canonical = canonicalTag?.attributes.href ?? "";
  const editLink = tags(html, "a").find(({ attributes: value }) =>
    value.href?.includes("github.com/neg4n/nobsprompt/edit/main/")
  );
  const robots = meta(html, "robots").toLowerCase();
  const jsonLd = [
    ...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/giu),
  ].filter(
    (match) =>
      attributes(match[1]).type?.toLowerCase() === "application/ld+json"
  );
  const links = tags(html, "link");
  const favicon = links.find(
    ({ attributes: value }) => value.rel?.toLowerCase() === "icon"
  );
  const appleIcon = links.find(
    ({ attributes: value }) =>
      value.rel?.toLowerCase() === "apple-touch-icon"
  );
  const author = tags(html, "a").find(
    ({ attributes: value }) => value["data-nobsprompt-author"] === "true"
  );
  const headerMarkup =
    html.match(/<header\b[^>]*data-blume-header[\s\S]*?<\/header>/iu)?.[0] ??
    "";
  const navigationToggle = tags(headerMarkup, "button").find(({ raw }) =>
    raw.includes("data-blume-nav-toggle")
  );
  const brandPosition = headerMarkup.indexOf("data-nobsprompt-brand");
  const togglePosition = headerMarkup.indexOf("data-blume-nav-toggle");

  if (!title) {
    fail(`${name} has no title`);
  }
  if (!meta(html, "description")) {
    fail(`${name} has no meta description`);
  }
  if (!canonical.startsWith(site)) {
    fail(`${name} has an invalid canonical URL: ${canonical || "(missing)"}`);
  } else {
    canonicalUrls.add(normalizeUrl(canonical));
  }
  if (robots.includes("noindex") || robots.includes("nofollow")) {
    fail(`${name} blocks indexing or link following`);
  }

  for (const key of [
    "og:title",
    "og:description",
    "og:url",
    "og:image",
    "twitter:card",
    "twitter:title",
    "twitter:description",
    "twitter:image",
  ]) {
    if (!meta(html, key)) {
      fail(`${name} is missing ${key}`);
    }
  }

  if (canonical && meta(html, "og:url") !== canonical) {
    fail(`${name} has different canonical and og:url values`);
  }
  if (!meta(html, "og:image").startsWith(site)) {
    fail(`${name} has a noncanonical Open Graph image`);
  }
  if (
    !editLink ||
    !new URL(editLink.attributes.href).pathname.startsWith(
      "/neg4n/nobsprompt/edit/main/docs/"
    )
  ) {
    fail(`${name} has an invalid GitHub edit link`);
  }
  if (jsonLd.length === 0) {
    fail(`${name} has no JSON-LD`);
  } else {
    for (const script of jsonLd) {
      try {
        JSON.parse(script[2]);
      } catch {
        fail(`${name} contains invalid JSON-LD`);
      }
    }
  }
  if (!favicon?.attributes.href?.endsWith("/icon.svg")) {
    fail(`${name} has an invalid favicon link`);
  }
  if (!appleIcon?.attributes.href?.endsWith("/apple-touch-icon.png")) {
    fail(`${name} has an invalid Apple touch icon link`);
  }
  if (
    !html.includes('data-nobsprompt-brand="true"') ||
    !/<span\b[^>]*data-nobsprompt-logo="true"[^>]*>[\s\S]*?<svg\b/iu.test(
      html
    )
  ) {
    fail(`${name} is missing the inline nobsprompt header brand`);
  }
  if (
    author?.attributes.href !== "https://neg4n.dev/" ||
    author.attributes.target !== "_blank" ||
    !author.attributes.rel?.split(/\s+/u).includes("author")
  ) {
    fail(`${name} has an invalid creator credit`);
  }
  if (
    !navigationToggle ||
    navigationToggle.attributes["aria-controls"] !==
      "blume-mobile-navigation" ||
    navigationToggle.attributes["aria-expanded"] !== "false" ||
    !navigationToggle.raw.includes("data-blume-nav-open-label") ||
    !navigationToggle.raw.includes("data-blume-nav-close-label")
  ) {
    fail(`${name} is missing the accessible mobile navigation toggle`);
  }
  if (
    brandPosition < 0 ||
    togglePosition < 0 ||
    togglePosition < brandPosition ||
    !headerMarkup.includes("data-blume-nav-close-icon")
  ) {
    fail(`${name} does not place the mobile navigation toggle on the right`);
  }
  if (
    !html.includes('data-blume-nav-gesture-zone') ||
    (html.match(/data-blume-nav-gesture-zone/gu)?.length ?? 0) !== 1
  ) {
    fail(`${name} is missing its single right-edge gesture zone`);
  }

  if ((html.match(/<h1\b/giu) ?? []).length !== 1) {
    fail(`${name} must contain exactly one h1`);
  }
  if (!/<main\b/iu.test(html) || !/<article\b/iu.test(html)) {
    fail(`${name} is missing semantic main or article markup`);
  }
  if (
    html.includes("Was this page helpful?") ||
    html.includes("data-blume-page-feedback")
  ) {
    fail(`${name} contains the disabled page feedback widget`);
  }
}

const homepage = read("index.html");
const optimizedVideos = [
  ...homepage.matchAll(/<optimized-video\b[\s\S]*?<\/optimized-video>/giu),
];

if (optimizedVideos.length !== 1) {
  fail("index.html must contain exactly one optimized landing video");
} else if (landingVideo) {
  const markup = optimizedVideos[0][0];
  const video = tags(markup, "video")[0];
  const deferredSources = tags(markup, "source").filter(
    ({ attributes: value }) => value["data-src"]
  );

  if (
    !markup.includes(
      `aspect-ratio: ${landingVideo.width} / ${landingVideo.height}`
    )
  ) {
    fail("the landing video does not reserve its source aspect ratio");
  }
  if (
    video?.attributes.width !== String(landingVideo.width) ||
    video.attributes.height !== String(landingVideo.height) ||
    video.attributes.preload !== "none" ||
    video.attributes.loading !== "lazy"
  ) {
    fail("the landing video is missing intrinsic dimensions or lazy loading");
  }
  for (const attribute of [
    "autoplay",
    "disablepictureinpicture",
    "disableremoteplayback",
    "loop",
    "muted",
    "playsinline",
    "webkit-playsinline",
  ]) {
    if (!new RegExp(`\\s${attribute}(?:\\s|=|>)`, "iu").test(video?.raw ?? "")) {
      fail(`the landing video is missing ${attribute}`);
    }
  }
  if (/\scontrols(?:\s|=|>)/iu.test(video?.raw ?? "")) {
    fail("the lazy landing video must not use native controls");
  }
  if (deferredSources.length !== landingVideo.videos.length) {
    fail("the landing video does not defer every encoded source");
  } else {
    for (const source of deferredSources) {
      if (
        !landingVideo.videos.some(
          (record) =>
            record.src === source.attributes["data-src"] &&
            record.type === decodeAttribute(source.attributes.type)
        )
      ) {
        fail(`the landing video contains an unknown source: ${source.raw}`);
      }
    }
  }
  if (
    !/<picture\b/iu.test(markup) ||
    !/data-control(?:\s|=|>)/iu.test(markup) ||
    !/aria-label="Pause demo video"/iu.test(markup) ||
    !/<noscript\b/iu.test(markup)
  ) {
    fail("the landing video is missing its poster, control, or fallback");
  }
}
if (homepage.includes("Video planned: nobsprompt in 15 seconds")) {
  fail("index.html still contains the obsolete landing-video placeholder");
}

const sitemap = read("sitemap.xml");
const sitemapUrls = new Set(
  [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/gu)].map((match) =>
    normalizeUrl(match[1])
  )
);

for (const canonical of canonicalUrls) {
  if (!sitemapUrls.has(canonical)) {
    fail(`sitemap.xml is missing ${canonical}`);
  }
}
for (const url of sitemapUrls) {
  if (!canonicalUrls.has(url)) {
    fail(`sitemap.xml contains a noncanonical page: ${url}`);
  }
}

const robots = read("robots.txt");
for (const expected of [
  "User-agent: *",
  "Allow: /",
  "Content-Signal: search=yes, ai-input=yes, ai-train=no",
  `Sitemap: ${site}/sitemap.xml`,
]) {
  if (!robots.includes(expected)) {
    fail(`robots.txt is missing: ${expected}`);
  }
}

const llms = read("llms.txt");
const llmsFull = read("llms-full.txt");
for (const canonical of canonicalUrls) {
  if (!llms.includes(canonical)) {
    fail(`llms.txt is missing ${canonical}`);
  }
}
if (!llmsFull.includes("# nobsprompt") || !llmsFull.includes("NBSP_DATA")) {
  fail("llms-full.txt does not contain the expected project corpus");
}

try {
  const agent = JSON.parse(read("agent-readability.json"));
  if (agent.site !== site) {
    fail("agent-readability.json has the wrong site URL");
  }
  if (agent.artifacts?.llmsTxt !== `${site}/llms.txt`) {
    fail("agent-readability.json has the wrong llms.txt URL");
  }
  if (agent.artifacts?.llmsFullTxt !== `${site}/llms-full.txt`) {
    fail("agent-readability.json has the wrong llms-full.txt URL");
  }
  if (
    agent.contentUsage?.search !== true ||
    agent.contentUsage?.["ai-input"] !== true ||
    agent.contentUsage?.["ai-train"] !== false
  ) {
    fail("agent-readability.json has the wrong content-use policy");
  }
} catch {
  fail("agent-readability.json is not valid JSON");
}

if (failures.length > 0) {
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log(
  `Verified ${htmlFiles.length} indexable static pages and crawler metadata.`
);
