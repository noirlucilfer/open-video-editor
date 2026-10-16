// Bridge between the Flutter web app and ffmpeg.wasm (@ffmpeg/ffmpeg 0.12).
//
// Exposes `window.oveWasm`:
//   - loadProgress:   0..1 while the ~31MB core downloads, -1 when idle/done
//   - exportProgress: 0..1 while an export runs, -1 when idle
//   - loadWasm():      downloads + instantiates the single-threaded core
//                       (no COOP/COEP headers required)
//   - runWasmExport(payloadJson): runs one export, triggers a browser
//                       download of the result, resolves to the exit code
//
// Payload: { args: string[], inputs: [{name, url}], outputName, fontUrl }

const FFMPEG_ESM =
  "https://cdn.jsdelivr.net/npm/@ffmpeg/ffmpeg@0.12.15/dist/esm/index.js";
const UTIL_ESM =
  "https://cdn.jsdelivr.net/npm/@ffmpeg/util@0.12.2/dist/esm/index.js";
const CORE_BASE = "https://cdn.jsdelivr.net/npm/@ffmpeg/core@0.12.6/dist/umd";

let ffmpeg = null;
let fetchFileFn = null;
let loadPromise = null;

async function fetchToBlobURL(url, mime, onProgress) {
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`fetch ${url}: ${resp.status}`);
  const total = parseInt(resp.headers.get("content-length") || "0", 10);
  const reader = resp.body.getReader();
  const chunks = [];
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    received += value.length;
    if (total > 0) onProgress(received / total);
  }
  return URL.createObjectURL(new Blob(chunks, { type: mime }));
}

async function loadWasm() {
  if (ffmpeg) return;
  if (loadPromise) return loadPromise;
  const W = window.oveWasm;
  loadPromise = (async () => {
    try {
      const { FFmpeg } = await import(FFMPEG_ESM);
      const util = await import(UTIL_ESM);
      fetchFileFn = util.fetchFile;
      const inst = new FFmpeg();
      inst.on("progress", ({ progress }) => {
        W.exportProgress = Math.max(0, Math.min(1, progress || 0));
      });
      W.loadProgress = 0;
      const coreURL = await fetchToBlobURL(
        `${CORE_BASE}/ffmpeg-core.js`, "text/javascript",
        (p) => { W.loadProgress = p * 0.2; });
      const wasmURL = await fetchToBlobURL(
        `${CORE_BASE}/ffmpeg-core.wasm`, "application/wasm",
        (p) => { W.loadProgress = 0.2 + p * 0.8; });
      await inst.load({ coreURL, wasmURL });
      ffmpeg = inst;
      W.loadProgress = -1;
    } catch (e) {
      loadPromise = null; // allow retry
      W.loadProgress = -1;
      throw e;
    }
  })();
  return loadPromise;
}

function triggerDownload(data, filename) {
  const blob = new Blob([data], { type: "video/mp4" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}

async function runWasmExport(payloadJson) {
  const W = window.oveWasm;
  try {
    const payload = JSON.parse(payloadJson);
    await loadWasm();
    const ff = ffmpeg;
    const written = [];
    for (const inp of payload.inputs) {
      await ff.writeFile(inp.name, await fetchFileFn(inp.url));
      written.push(inp.name);
    }
    if (payload.fontUrl && payload.args.join(" ").includes("ove-font.ttf")) {
      await ff.writeFile("ove-font.ttf", await fetchFileFn(payload.fontUrl));
      written.push("ove-font.ttf");
    }
    W.exportProgress = 0;
    const code = await ff.exec(payload.args);
    W.exportProgress = -1;
    if (code === 0) {
      const data = await ff.readFile(payload.outputName);
      triggerDownload(data, payload.outputName);
    }
    for (const name of [...written, payload.outputName]) {
      try { await ff.deleteFile(name); } catch (_) {}
    }
    return code;
  } catch (e) {
    console.error("[oveWasm] export failed", e);
    W.exportProgress = -1;
    return 1;
  }
}

window.oveWasm = {
  loadProgress: -1,
  exportProgress: -1,
  loadWasm,
  runWasmExport,
};
