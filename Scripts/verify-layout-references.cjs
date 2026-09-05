const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "ReferenceCaptures", "manifest.json"), "utf8"));
const raw = path.join(root, "ReferenceCaptures", "raw");
let failed = false;

for (const capture of manifest.captures) {
  const file = path.join(raw, capture.filename);
  if (!fs.existsSync(file)) {
    console.error(`missing ${capture.filename}`);
    failed = true;
    continue;
  }
  const data = fs.readFileSync(file);
  const signature = data.subarray(0, 8).toString("hex");
  if (signature !== "89504e470d0a1a0a") {
    console.error(`${capture.filename}: expected an original PNG`);
    failed = true;
    continue;
  }
  const width = data.readUInt32BE(16);
  const height = data.readUInt32BE(20);
  const digest = crypto.createHash("sha256").update(data).digest("hex");
  if (width !== capture.pixelWidth || height !== capture.pixelHeight || digest !== capture.sha256) {
    console.error(`${capture.filename}: manifest mismatch (${width}x${height}, ${digest})`);
    failed = true;
  } else {
    console.log(`${capture.filename}: verified`);
  }
}

process.exitCode = failed ? 1 : 0;
