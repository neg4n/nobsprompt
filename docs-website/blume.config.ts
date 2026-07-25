import { defineConfig } from "blume";

const movedDocumentation = [
  ["/custom-prompts", "/detached-mode"],
  ["/custom-prompts/data-lifecycle", "/detached-mode/data-lifecycle"],
  ["/custom-prompts/recipes", "/detached-mode/recipes"],
  ["/custom-prompts/direct-data", "/reference/data-protocol"],
] as const;

const redirects = movedDocumentation.flatMap(([from, to]) =>
  ["", ".md", ".mdx"].map((suffix) => ({
    from: `${from}${suffix}`,
    status: 301 as const,
    to: `${to}${suffix}`,
  }))
);

export default defineConfig({
  title: "nobsprompt",
  description:
    "An extremely lightweight prompt backend for macOS and Zsh, with an opinionated prompt ready to use.",
  logo: {
    image: "/logo.svg",
    text: "nobsprompt",
  },
  content: {
    root: "../docs",
  },
  github: {
    owner: "neg4n",
    repo: "nobsprompt",
    branch: "main",
    dir: "docs-website",
  },
  theme: {
    accent: "green",
    radius: "sm",
    mode: "system",
  },
  search: {
    provider: "orama",
  },
  feedback: false,
  redirects,
  markdown: {
    code: {
      icons: true,
      wrap: false,
    },
  },
  navigation: {
    sidebar: {
      display: "flat",
      items: [
        "/",
        {
          label: "Get started",
          icon: "rocket",
          root: "/get-started",
          items: ["/get-started/opinionated-prompt"],
        },
        {
          label: "Detached mode",
          icon: "code",
          root: "/detached-mode",
          items: [
            "/detached-mode/data-lifecycle",
            "/detached-mode/recipes",
          ],
        },
        {
          label: "Internals",
          icon: "activity",
          root: "/internals",
          items: ["/internals/performance"],
        },
        {
          label: "Reference",
          icon: "book-open",
          items: [
            "/reference/cli",
            "/reference/data-protocol",
            "/reference/configuration",
            "/reference/external-editor",
          ],
        },
      ],
    },
  },
  ai: {
    llmsTxt: true,
    mcp: {
      enabled: false,
    },
  },
  seo: {
    contentSignals: {
      search: true,
      aiInput: true,
      aiTrain: false,
    },
    og: {
      enabled: true,
      logo: "/logo.svg",
    },
    sitemap: true,
    robots: true,
    structuredData: true,
  },
  deployment: {
    output: "static",
    site: "https://nobsprompt.pages.dev",
  },
});
