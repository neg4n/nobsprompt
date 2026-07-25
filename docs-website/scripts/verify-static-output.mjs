import { readFileSync, readdirSync, statSync } from "node:fs";
import { relative, resolve } from "node:path";

const site = "https://nobsprompt.pages.dev";
const dist = resolve("dist");
const failures = [];

const fail = (message) => {
  failures.push(message);
};

const read = (path) => readFileSync(resolve(dist, path), "utf8");

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
]) {
  requireFile(path, path.startsWith("llms") ? 100 : 1);
}

const allFiles = walk(dist);
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
