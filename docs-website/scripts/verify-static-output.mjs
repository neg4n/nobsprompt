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
const movedDocumentation = [
  ["/custom-prompts", "/detached-mode"],
  ["/custom-prompts/data-lifecycle", "/detached-mode/data-lifecycle"],
  ["/custom-prompts/recipes", "/detached-mode/recipes"],
  ["/custom-prompts/direct-data", "/reference/data-protocol"],
];
const expectedRedirects = movedDocumentation.flatMap(([from, to]) =>
  ["", ".md", ".mdx"].map((suffix) => ({
    from: `${from}${suffix}`,
    status: 301,
    to: `${to}${suffix}`,
  }))
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
  "blume-search.json",
  "llms.txt",
  "llms-full.txt",
  "agent-readability.json",
  "index.md",
  "index.mdx",
  "get-started.md",
  "detached-mode/data-lifecycle.md",
  "reference/autosuggestions.md",
  "reference/data-protocol.md",
  "logo.svg",
  "icon.svg",
  "logo-light.svg",
  "logo-dark.svg",
  "apple-touch-icon.png",
  "_headers",
  "_redirects",
  "blume-redirects.json",
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

const isRedirectHtml = (path) =>
  tags(readFileSync(path, "utf8"), "meta").some(
    ({ attributes: value }) => value["http-equiv"]?.toLowerCase() === "refresh"
  );
const redirectHtmlFiles = allFiles.filter(
  (path) => path.endsWith(".html") && isRedirectHtml(path)
);
const htmlFiles = allFiles.filter(
  (path) =>
    path.endsWith(".html") &&
    relative(dist, path) !== "404.html" &&
    !isRedirectHtml(path)
);
const canonicalUrls = new Set();

const logo = readBuffer("logo.svg");
const icon = readBuffer("icon.svg");
const logoText = logo.toString("utf8");
const logoLightText = read("logo-light.svg");
const logoDarkText = read("logo-dark.svg");
const appleTouchIcon = readBuffer("apple-touch-icon.png");
const headers = read("_headers");
const redirectRules = read("_redirects");
const redirectManifest = JSON.parse(read("blume-redirects.json"));

if (JSON.stringify(redirectManifest) !== JSON.stringify(expectedRedirects)) {
  fail("the redirect manifest does not match the documentation route migration");
}
for (const { from, status, to } of expectedRedirects) {
  if (!redirectRules.split("\n").includes(`${from} ${to} ${status}`)) {
    fail(`_redirects is missing ${from} -> ${to}`);
  }
}
if (redirectHtmlFiles.length !== expectedRedirects.length) {
  fail(
    `expected ${expectedRedirects.length} static redirect pages, found ${redirectHtmlFiles.length}`
  );
}

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
const homepageMarkdown = read("index.md");
const getStarted = read("get-started/index.html");
const getStartedMarkdown = read("get-started.md");
const dataLifecycleMarkdown = read("detached-mode/data-lifecycle.md");
const dataProtocolMarkdown = read("reference/data-protocol.md");
const sparseSelection = "git sparse-checkout set src tools tests doc docs";
const normalizedGetStartedMarkdown = getStartedMarkdown.replace(/\s+/gu, " ");

for (const [name, content] of [["get-started.md", getStartedMarkdown]]) {
  if (
    !content.includes("git clone --depth 1 --filter=blob:none --sparse --no-tags") ||
    !content.includes(sparseSelection) ||
    !content.includes("make install")
  ) {
    fail(`${name} is missing the partial-clone installation flow`);
  }
  if (content.includes("make test")) {
    fail(`${name} includes the maintainer test command in the user quickstart`);
  }
  if (/git sparse-checkout set[^\n<]*docs-website/iu.test(content)) {
    fail(`${name} includes docs-website in the sparse checkout`);
  }
}
if (
  homepageMarkdown.includes("git clone --depth 1") ||
  homepageMarkdown.includes("make install") ||
  homepageMarkdown.includes("## Install from source")
) {
  fail("the homepage contains installation instructions reserved for get-started");
}
if (
  !getStartedMarkdown.includes(
    "git clone https://github.com/neg4n/nobsprompt.git && cd nobsprompt"
  )
) {
  fail("get-started is missing the full-clone alternative");
}

const clonePosition = getStartedMarkdown.indexOf("git clone --depth 1");
const auditPosition = getStartedMarkdown.indexOf("Review the exact source");
const installPosition = getStartedMarkdown.lastIndexOf("make install");
if (
  clonePosition < 0 ||
  auditPosition <= clonePosition ||
  installPosition <= auditPosition
) {
  fail("get-started does not place source review between clone and install");
}
if (
  (getStarted.match(/<blume-prompt\b/gu)?.length ?? 0) !== 1 ||
  !getStarted.includes('aria-label="Copy prompt"') ||
  !getStarted.includes("data-blume-prompt-copy") ||
  !getStarted.includes("data-blume-prompt-content hidden") ||
  !getStarted.includes("Treat this checkout as untrusted") ||
  !compiledJavaScript.includes("navigator.clipboard.writeText")
) {
  fail("get-started is missing its functional copyable source-audit prompt");
}
for (const token of [
  "Treat this checkout as untrusted",
  "Trace the complete `make install` control flow",
  "cryptocurrency mining behavior",
  "Do not claim proof of safety",
]) {
  if (!normalizedGetStartedMarkdown.includes(token)) {
    fail(`agent-facing get-started Markdown is missing: ${token}`);
  }
}
if (
  !homepageMarkdown.includes("## Features") ||
  !homepageMarkdown.includes("54 KiB") ||
  !homepageMarkdown.includes("live, path-aware `cd` suggestions") ||
  !homepageMarkdown.includes('href="/reference/autosuggestions"') ||
  homepageMarkdown.includes("## What the backend provides")
) {
  fail("the homepage does not present the revised Features section");
}
for (const token of [
  'eval "$(nbsp init zsh --autosuggest)"',
  'eval "$(nbsp init zsh --detached --autosuggest)"',
  "Use one autosuggestion engine",
  "zsh-autosuggestions",
  "omit `--autosuggest`",
]) {
  if (!normalizedGetStartedMarkdown.includes(token)) {
    fail(`get-started autosuggestion guidance is missing: ${token}`);
  }
}
for (const token of [
  "`path` is the abbreviated display path",
  'nbsp_prompt_escape "${NBSP_DATA[cwd]}"',
  "comes from `getcwd(3)`",
  "do not call `realpath`",
  "logical, symlink-preserving path",
]) {
  if (!dataLifecycleMarkdown.includes(token)) {
    fail(`detached path guidance is missing: ${token}`);
  }
}
for (const token of [
  "`cwd` is the full physical working directory",
  "`path` is its abbreviated",
  "`NBSP_DATA[cwd]`",
  "do not need to start `realpath`",
]) {
  if (!dataProtocolMarkdown.includes(token)) {
    fail(`data protocol path guidance is missing: ${token}`);
  }
}

const sidebarMarkup =
  homepage.match(
    /<aside\b[^>]*data-blume-nav-drawer[\s\S]*?<\/aside>/iu
  )?.[0] ?? "";
const sidebarLabels = [
  ...sidebarMarkup.matchAll(/<span\b[^>]*>([^<]+)<\/span>/giu),
].map((match) => match[1].trim());
const expectedSidebarLabels = [
  "nobsprompt",
  "Get started",
  "Opinionated prompt",
  "Autosuggestions",
  "Detached mode",
  "Data and lifecycle",
  "Prompt recipes",
  "Internals",
  "Performance and memory",
  "Reference",
  "CLI reference",
  "Data protocol",
  "Configuration",
  "External command editor",
];

if (JSON.stringify(sidebarLabels) !== JSON.stringify(expectedSidebarLabels)) {
  fail(
    `the sidebar hierarchy is unexpected: ${JSON.stringify(sidebarLabels)}`
  );
}

const sidebarLinks = [
  ...sidebarMarkup.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu),
].map((match) => ({
  href: attributes(match[1]).href,
  label: match[2].replace(/<[^>]+>/gu, " ").replace(/\s+/gu, " ").trim(),
}));
for (const [label, href] of [
  ["Get started", "/get-started"],
  ["Autosuggestions", "/reference/autosuggestions"],
  ["Detached mode", "/detached-mode"],
  ["Internals", "/internals"],
]) {
  const links = sidebarLinks.filter((link) => link.label === label);
  if (links.length !== 1 || links[0].href !== href) {
    fail(`${label} must appear once as a linked section heading`);
  }
}

const crawlerArtifacts = {
  "agent-readability.json": read("agent-readability.json"),
  "blume-search.json": read("blume-search.json"),
  "llms-full.txt": read("llms-full.txt"),
  "llms.txt": read("llms.txt"),
  "sitemap.xml": read("sitemap.xml"),
};
for (const [name, content] of Object.entries(crawlerArtifacts)) {
  if (content.includes("/custom-prompts")) {
    fail(`${name} contains a retired custom-prompts route`);
  }
}
const routeBearingArtifacts = {
  "blume-search.json": crawlerArtifacts["blume-search.json"],
  "llms-full.txt": crawlerArtifacts["llms-full.txt"],
  "llms.txt": crawlerArtifacts["llms.txt"],
  "sitemap.xml": crawlerArtifacts["sitemap.xml"],
};
for (const route of [
  "/detached-mode",
  "/detached-mode/data-lifecycle",
  "/detached-mode/recipes",
  "/reference/autosuggestions",
  "/reference/data-protocol",
]) {
  for (const [name, content] of Object.entries(routeBearingArtifacts)) {
    if (!content.includes(route)) {
      fail(`${name} is missing ${route}`);
    }
  }
}
if (
  !crawlerArtifacts["llms.txt"].includes("## Detached mode") ||
  !crawlerArtifacts["llms.txt"].includes("## Reference") ||
  crawlerArtifacts["llms.txt"].includes("Custom prompts") ||
  crawlerArtifacts["llms.txt"].includes("Direct data output")
) {
  fail("llms.txt does not present the revised prompt-mode hierarchy");
}

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
