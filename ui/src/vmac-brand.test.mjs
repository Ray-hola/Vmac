import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// PNG header: 8-byte signature, then IHDR with width, height, bit depth and color type.
function header(path) {
  const data = readFileSync(new URL(path, import.meta.url));
  assert.equal(data.subarray(1, 4).toString("latin1"), "PNG", `${path} is a PNG`);
  return { width: data.readUInt32BE(16), height: data.readUInt32BE(20), colorType: data[25] };
}

test("the otter master is a square image with transparency", () => {
  const master = header("../../assets/branding/vmac-otter.png");
  assert.equal(master.width, master.height);
  assert.ok(master.width >= 1024, "large enough for the 1024 px app icon");
  assert.equal(master.colorType, 6, "RGBA");
});
test("the web mark is a 512 px square with transparency", () => {
  assert.deepEqual(header("./vmac-mark.png"), { width: 512, height: 512, colorType: 6 });
});
