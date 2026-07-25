import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sourceRelativePath = "assets/videos/nobsprompt-demo.mp4";
const sourcePath = resolve(projectRoot, sourceRelativePath);
const mediaDirectory = resolve(projectRoot, "public/media");
const manifestPath = resolve(
  projectRoot,
  "assets/videos/video-manifest.json"
);
const assetName = "nobsprompt-demo";
const mode = process.argv[2];

const expectedSource = {
  duration: 46.334,
  fps: 30,
  height: 1080,
  width: 1632,
};

if (mode !== "--check" && mode !== "--write") {
  console.error("Usage: node scripts/video-assets.mjs --check|--write");
  process.exit(2);
}

const sha256 = (content) =>
  createHash("sha256").update(content).digest("hex");

const boxTree = (buffer, start = 0, end = buffer.length) => {
  const containers = new Set(["mdia", "minf", "moov", "stbl", "trak"]);
  const boxes = [];
  let offset = start;

  while (offset + 8 <= end) {
    let size = buffer.readUInt32BE(offset);
    const type = buffer.toString("ascii", offset + 4, offset + 8);
    let headerSize = 8;

    if (size === 1) {
      if (offset + 16 > end) {
        break;
      }
      size = Number(buffer.readBigUInt64BE(offset + 8));
      headerSize = 16;
    } else if (size === 0) {
      size = end - offset;
    }

    if (size < headerSize || offset + size > end) {
      break;
    }

    const box = {
      children: [],
      end: offset + size,
      payload: offset + headerSize,
      size,
      start: offset,
      type,
    };

    if (containers.has(type)) {
      box.children = boxTree(buffer, box.payload, box.end);
    }

    boxes.push(box);
    offset += size;
  }

  return boxes;
};

const findBoxes = (boxes, type) =>
  boxes.flatMap((box) => [
    ...(box.type === type ? [box] : []),
    ...findBoxes(box.children, type),
  ]);

const handlerType = (buffer, box) =>
  buffer.toString("ascii", box.payload + 8, box.payload + 12);

const mp4Metadata = (buffer) => {
  const boxes = boxTree(buffer);
  const movieHeader = findBoxes(boxes, "mvhd")[0];
  const videoTrack = findBoxes(boxes, "trak").find((track) =>
    findBoxes(track.children, "hdlr").some(
      (handler) => handlerType(buffer, handler) === "vide"
    )
  );

  if (!movieHeader || !videoTrack) {
    throw new Error("The source MP4 is missing movie or video metadata.");
  }

  const movieVersion = buffer[movieHeader.payload];
  const movieTimescaleOffset =
    movieHeader.payload + (movieVersion === 1 ? 20 : 12);
  const movieDurationOffset = movieTimescaleOffset + 4;
  const movieTimescale = buffer.readUInt32BE(movieTimescaleOffset);
  const movieDuration =
    movieVersion === 1
      ? Number(buffer.readBigUInt64BE(movieDurationOffset))
      : buffer.readUInt32BE(movieDurationOffset);
  const trackHeader = findBoxes(videoTrack.children, "tkhd")[0];
  const mediaHeader = findBoxes(videoTrack.children, "mdhd")[0];
  const timing = findBoxes(videoTrack.children, "stts")[0];

  if (!trackHeader || !mediaHeader || !timing) {
    throw new Error("The source MP4 is missing video track metadata.");
  }

  const mediaVersion = buffer[mediaHeader.payload];
  const mediaTimescaleOffset =
    mediaHeader.payload + (mediaVersion === 1 ? 20 : 12);
  const mediaTimescale = buffer.readUInt32BE(mediaTimescaleOffset);
  const timingEntries = buffer.readUInt32BE(timing.payload + 4);
  let timingOffset = timing.payload + 8;
  let samples = 0;
  let ticks = 0;

  for (let index = 0; index < timingEntries; index += 1) {
    const count = buffer.readUInt32BE(timingOffset);
    const delta = buffer.readUInt32BE(timingOffset + 4);
    samples += count;
    ticks += count * delta;
    timingOffset += 8;
  }

  return {
    duration: movieDuration / movieTimescale,
    fps: samples / (ticks / mediaTimescale),
    hasAudio: findBoxes(boxes, "hdlr").some(
      (handler) => handlerType(buffer, handler) === "soun"
    ),
    height: buffer.readUInt32BE(trackHeader.end - 4) / 65536,
    topLevelBoxes: boxes.map(({ type }) => type),
    width: buffer.readUInt32BE(trackHeader.end - 8) / 65536,
  };
};

const assertSourceMetadata = (metadata) => {
  for (const key of ["fps", "height", "width"]) {
    if (metadata[key] !== expectedSource[key]) {
      throw new Error(
        `Unexpected source ${key}: ${metadata[key]} instead of ${expectedSource[key]}.`
      );
    }
  }

  if (Math.abs(metadata.duration - expectedSource.duration) > 0.01) {
    throw new Error(
      `Unexpected source duration: ${metadata.duration.toFixed(3)} seconds.`
    );
  }

  if (metadata.hasAudio) {
    throw new Error("The landing demo must not contain an audio track.");
  }
};

const run = (command, arguments_) =>
  new Promise((resolvePromise, reject) => {
    const child = spawn(command, arguments_, { stdio: "inherit" });
    child.on("error", reject);
    child.on("exit", (code, signal) => {
      if (code === 0) {
        resolvePromise();
      } else {
        reject(
          new Error(
            `${basename(command)} failed with ${signal ? `signal ${signal}` : `status ${code}`}.`
          )
        );
      }
    });
  });

const hashedName = (label, extension, content) =>
  `${assetName}.${label}.${sha256(content).slice(0, 12)}.${extension}`;

const publicAsset = async (label, extension, content) => {
  const name = hashedName(label, extension, content);
  await writeFile(resolve(mediaDirectory, name), content);
  return {
    bytes: content.length,
    sha256: sha256(content),
    src: `/media/${name}`,
  };
};

const buildAssets = async (source, metadata) => {
  const ffmpeg = process.env.FFMPEG_PATH || "ffmpeg";
  const temporaryDirectory = await mkdtemp(
    join(tmpdir(), "nobsprompt-video-")
  );

  try {
    await run(ffmpeg, ["-version"]);
  } catch {
    throw new Error(
      "FFmpeg was not found. Install it or set FFMPEG_PATH before running pnpm video:build."
    );
  }

  try {
    const mp4Path = resolve(temporaryDirectory, `${assetName}.mp4`);
    const webmPath = resolve(temporaryDirectory, `${assetName}.webm`);
    const posterPath = resolve(temporaryDirectory, `${assetName}.png`);

    await run(ffmpeg, [
      "-y",
      "-i",
      sourcePath,
      "-map",
      "0:v:0",
      "-an",
      "-sn",
      "-dn",
      "-map_metadata",
      "-1",
      "-vf",
      "fps=30,format=yuv420p",
      "-c:v",
      "libx264",
      "-preset",
      "slow",
      "-crf",
      "22",
      "-profile:v",
      "high",
      "-level:v",
      "4.1",
      "-g",
      "60",
      "-keyint_min",
      "60",
      "-sc_threshold",
      "0",
      "-movflags",
      "+faststart",
      mp4Path,
    ]);

    await run(ffmpeg, [
      "-y",
      "-i",
      sourcePath,
      "-map",
      "0:v:0",
      "-an",
      "-sn",
      "-dn",
      "-map_metadata",
      "-1",
      "-vf",
      "fps=30,format=yuv420p",
      "-c:v",
      "libvpx-vp9",
      "-crf",
      "30",
      "-b:v",
      "0",
      "-deadline",
      "good",
      "-cpu-used",
      "2",
      "-row-mt",
      "1",
      "-g",
      "120",
      webmPath,
    ]);

    await run(ffmpeg, [
      "-y",
      "-ss",
      "1",
      "-i",
      sourcePath,
      "-frames:v",
      "1",
      "-vf",
      `scale=${metadata.width}:${metadata.height}:flags=lanczos`,
      posterPath,
    ]);

    const [mp4, webm, poster] = await Promise.all([
      readFile(mp4Path),
      readFile(webmPath),
      readFile(posterPath),
    ]);

    const mp4Info = mp4Metadata(mp4);
    const moov = mp4Info.topLevelBoxes.indexOf("moov");
    const mdat = mp4Info.topLevelBoxes.indexOf("mdat");

    if (moov < 0 || mdat < 0 || moov > mdat) {
      throw new Error("The generated MP4 is not optimized for fast start.");
    }

    await mkdir(mediaDirectory, { recursive: true });
    const previous = await readdir(mediaDirectory);
    await Promise.all(
      previous
        .filter((name) => name.startsWith(`${assetName}.`))
        .map((name) => rm(resolve(mediaDirectory, name)))
    );

    const videos = [
      {
        ...(await publicAsset("vp9", "webm", webm)),
        type: 'video/webm; codecs="vp9"',
      },
      {
        ...(await publicAsset("h264", "mp4", mp4)),
        type: 'video/mp4; codecs="avc1.640029"',
      },
    ];

    const posters = {
      avif: [],
      jpeg: undefined,
      webp: [],
    };

    for (const width of [816, 1632]) {
      const avif = await sharp(poster)
        .resize({ width, withoutEnlargement: true })
        .avif({ effort: 6, quality: 50 })
        .toBuffer();
      const webp = await sharp(poster)
        .resize({ width, withoutEnlargement: true })
        .webp({ effort: 6, quality: 80 })
        .toBuffer();

      posters.avif.push({
        ...(await publicAsset(`poster-${width}`, "avif", avif)),
        width,
      });
      posters.webp.push({
        ...(await publicAsset(`poster-${width}`, "webp", webp)),
        width,
      });
    }

    const jpeg = await sharp(poster)
      .jpeg({ mozjpeg: true, progressive: true, quality: 82 })
      .toBuffer();
    posters.jpeg = {
      ...(await publicAsset("poster-1632", "jpg", jpeg)),
      width: 1632,
    };

    const placeholder = await sharp(poster)
      .resize({ width: 32 })
      .webp({ effort: 6, quality: 35 })
      .toBuffer();

    return {
      version: 1,
      assets: {
        [assetName]: {
          duration: Number(metadata.duration.toFixed(3)),
          fps: metadata.fps,
          height: metadata.height,
          placeholder: `data:image/webp;base64,${placeholder.toString("base64")}`,
          posters,
          source: sourceRelativePath,
          sourceBytes: source.length,
          sourceSha256: sha256(source),
          videos,
          width: metadata.width,
        },
      },
    };
  } finally {
    await rm(temporaryDirectory, { force: true, recursive: true });
  }
};

const validateAssetFile = async (record, maximumBytes) => {
  const name = basename(record.src);
  const content = await readFile(resolve(mediaDirectory, name));

  if (content.length !== record.bytes || sha256(content) !== record.sha256) {
    throw new Error(`${name} does not match its manifest hash.`);
  }
  if (!name.includes(record.sha256.slice(0, 12))) {
    throw new Error(`${name} does not contain its content hash.`);
  }
  if (content.length > maximumBytes) {
    throw new Error(`${name} exceeds its ${maximumBytes}-byte budget.`);
  }

  return content;
};

const checkAssets = async (source, metadata) => {
  let manifest;

  try {
    manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  } catch {
    throw new Error(
      "The video manifest is missing or invalid. Run pnpm video:build."
    );
  }

  const asset = manifest?.version === 1 ? manifest.assets?.[assetName] : null;

  if (!asset) {
    throw new Error("The video manifest does not contain nobsprompt-demo.");
  }
  if (
    asset.source !== sourceRelativePath ||
    asset.sourceSha256 !== sha256(source) ||
    asset.sourceBytes !== source.length
  ) {
    throw new Error("The video manifest is stale for its canonical source.");
  }

  for (const key of ["duration", "fps", "height", "width"]) {
    if (Math.abs(asset[key] - metadata[key]) > 0.01) {
      throw new Error(`The video manifest has an invalid ${key}.`);
    }
  }

  if (
    !asset.placeholder?.startsWith("data:image/webp;base64,") ||
    asset.placeholder.length > 8000
  ) {
    throw new Error("The inline video placeholder is missing or too large.");
  }
  if (asset.videos?.length !== 2) {
    throw new Error("The manifest must contain WebM and MP4 video variants.");
  }

  const expectedFiles = [];

  for (const video of asset.videos) {
    const content = await validateAssetFile(video, 8 * 1024 * 1024);
    expectedFiles.push(basename(video.src));

    if (video.type.startsWith("video/mp4")) {
      const metadata_ = mp4Metadata(content);
      const moov = metadata_.topLevelBoxes.indexOf("moov");
      const mdat = metadata_.topLevelBoxes.indexOf("mdat");
      if (moov < 0 || mdat < 0 || moov > mdat) {
        throw new Error("The generated MP4 is not optimized for fast start.");
      }
    } else if (
      video.type.startsWith("video/webm") &&
      content.subarray(0, 4).toString("hex") !== "1a45dfa3"
    ) {
      throw new Error("The generated WebM has an invalid EBML signature.");
    }
  }

  for (const format of ["avif", "webp"]) {
    if (asset.posters?.[format]?.length !== 2) {
      throw new Error(`The manifest must contain two ${format} posters.`);
    }

    for (const poster of asset.posters[format]) {
      const content = await validateAssetFile(poster, 350 * 1024);
      const image = await sharp(content).metadata();
      expectedFiles.push(basename(poster.src));

      if (
        (format === "avif"
          ? image.mediaType !== "image/avif"
          : image.format !== format) ||
        image.width !== poster.width ||
        image.height !== Math.round((poster.width * metadata.height) / metadata.width)
      ) {
        throw new Error(`${basename(poster.src)} has invalid image metadata.`);
      }
    }
  }

  const jpeg = asset.posters?.jpeg;
  const jpegContent = await validateAssetFile(jpeg, 350 * 1024);
  const jpegMetadata = await sharp(jpegContent).metadata();
  expectedFiles.push(basename(jpeg.src));

  if (
    jpegMetadata.format !== "jpeg" ||
    jpegMetadata.width !== metadata.width ||
    jpegMetadata.height !== metadata.height
  ) {
    throw new Error("The JPEG video poster has invalid image metadata.");
  }

  const actualFiles = (await readdir(mediaDirectory))
    .filter((name) => name.startsWith(`${assetName}.`))
    .sort();

  if (actualFiles.join("\n") !== expectedFiles.sort().join("\n")) {
    throw new Error("Generated video assets are missing or stale.");
  }
};

const source = await readFile(sourcePath);
const metadata = mp4Metadata(source);
assertSourceMetadata(metadata);

if (mode === "--write") {
  const manifest = await buildAssets(source, metadata);
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log("Generated optimized landing demo video assets.");
} else {
  await checkAssets(source, metadata);
  console.log("Video assets match the canonical recording.");
}
