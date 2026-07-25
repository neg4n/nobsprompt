import { defineConfig } from "blume";

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
  markdown: {
    code: {
      icons: true,
      wrap: false,
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
