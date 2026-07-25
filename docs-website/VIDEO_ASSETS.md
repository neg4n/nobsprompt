# Documentation video assets

The canonical landing-page recording is
`assets/videos/nobsprompt-demo.mp4`. Generated browser formats and posters live
under `public/media/` and are described by
`assets/videos/video-manifest.json`.

## Regenerating media

Changing the canonical recording requires FFmpeg on `PATH`, or an explicit
`FFMPEG_PATH`. From `docs-website/`, run:

```sh
pnpm run video:build
pnpm run video:check
```

The build creates a fast-start H.264 MP4, a VP9 WebM, responsive AVIF and WebP
posters, a JPEG fallback, and a tiny inline placeholder. Output filenames carry
content hashes and are safe to cache immutably.

Generated media is committed to Git. Cloudflare Pages runs `video:check`, which
validates source and output hashes without downloading FFmpeg or transcoding
the video during deployment.

## Component behavior

`components/OptimizedVideo.astro` reserves the source aspect ratio before any
media loads. Its poster is available immediately, while video sources are
attached only near the viewport.

Muted autoplay uses inline playback on mobile. The component pauses offscreen,
respects reduced-motion and data-saving preferences, and leaves the poster with
a Play button whenever autoplay is unavailable. It never requests fullscreen.
