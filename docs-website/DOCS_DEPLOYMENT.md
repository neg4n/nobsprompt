# Documentation deployment

The documentation site is a fully static Blume build deployed through
Cloudflare Pages Git integration. A merge to `main` triggers the production
build. No Worker, Pages Function, adapter, secret, or runtime environment is
required.

## Local build

Run these commands from `docs-website/`. Use the Node and pnpm versions pinned
in this directory:

```sh
corepack enable
pnpm install --frozen-lockfile
pnpm run docs:ci
```

The deployable output is written to `dist/`.

## One-time Cloudflare Pages setup

1. Push this repository to `https://github.com/neg4n/nobsprompt`.
2. In the Cloudflare dashboard, open **Workers & Pages**, then select
   **Create application** and **Pages**.
3. Choose **Connect to Git** and select `neg4n/nobsprompt`.
4. Configure the project with these exact values:

| Setting | Value |
| --- | --- |
| Project name | `nobsprompt` |
| Production branch | `main` |
| Preview branch deployments | None |
| Root directory | `docs-website` |
| Build command | `pnpm run docs:ci` |
| Build output directory | `dist` |
| Build system version | Version 3 |

5. Add these build environment variables:

| Variable | Value |
| --- | --- |
| `NODE_VERSION` | `22.22.0` |
| `PNPM_VERSION` | `10.34.5` |

6. Save and deploy. The expected production address is
   `https://nobsprompt.pages.dev`.

Cloudflare's Git integration becomes the documentation CI/CD path. Each merge
to `main` creates a production deployment only after the checks, validation,
static build, and audit in `pnpm run docs:ci` succeed.

## Static-only guardrails

Keep these properties intact:

- `deployment.output` remains `"static"` in `blume.config.ts`;
- no Cloudflare adapter is installed or configured;
- no `functions/` directory, Worker entry point, or Wrangler deployment command
  is added;
- search remains the client-side Orama provider;
- Ask AI and the hosted MCP server remain disabled.

The generated `sitemap.xml`, `robots.txt`, Open Graph images, search data, raw
Markdown routes, `llms.txt`, and `llms-full.txt` are static files inside
`dist/`.

Content-hashed video files and responsive posters are also copied from
`public/media/`. They are generated locally and committed, so Cloudflare only
validates and serves them. See `VIDEO_ASSETS.md` before replacing a recording.

## Changing versions

Update the following together:

- Node in `.node-version` and `package.json`;
- pnpm in `package.json` and the Cloudflare `PNPM_VERSION` variable;
- Blume in `package.json` and `pnpm-lock.yaml`.

Run `pnpm run docs:ci` before merging any version change.

## Zig branch promotion

The rewrite is developed on `codex/zig-rewrite`. Cloudflare Pages continues to
track `main` until the rewrite passes acceptance. Changing the GitHub default
branch does not change the Pages production branch. At promotion, change Pages'
production branch to `codex/zig-rewrite`, run the pinned `docs:ci` build, and
verify the deployed site. Keep `main` and the C reference revision available
for rollback. No deployment or remote branch-setting change is implied by a
local build.
