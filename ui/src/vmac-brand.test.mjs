import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";

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

// The crab in a cage was the mark of the project VMac grew out of. Nothing
// VMac shows may bring it back.
const repo = new URL("../../", import.meta.url);
test("the crab-cage image files are gone", () => {
  for (const path of ["logo.png", "ui/src/logo.png", "ui/public/cage.png", "ui/public/cage.svg"]) {
    assert.equal(existsSync(new URL(path, repo)), false, `${path} should not exist`);
  }
});
test("no page, style or script names the crab-cage image", () => {
  const old = /logo\.png|cage\.(png|svg)/;
  const folders = ["ui/src/", "ui/src/mobile-cli/", "ui/", "ui/scripts/", "scripts/"];
  for (const folder of folders) {
    const here = new URL(folder, repo);
    for (const name of readdirSync(here).filter(file => /\.(jsx?|mjs|css|html|sh)$/.test(file) && !file.endsWith(".test.mjs"))) {
      assert.doesNotMatch(readFileSync(new URL(name, here), "utf8"), old, `${folder}${name} names the old image`);
    }
  }
});
test("every page takes its mark from one place, and that place is the otter", () => {
  const source = readFileSync(new URL("./brand-logo.js", import.meta.url), "utf8");
  assert.match(source, /vmac-mark\.png/);
  assert.doesNotMatch(source, /cageNativeVMWorkbench/, "the mark no longer depends on the product");
});
test("the page icon in a browser tab is the otter", () => {
  assert.deepEqual(header("../public/vmac.png"), { width: 512, height: 512, colorType: 6 });
  for (const page of ["ui/index.html", "ui/mobile.html"]) {
    assert.match(readFileSync(new URL(page, repo), "utf8"), /<link rel="icon"[^>]*href="\/vmac\.png"/, `${page} links the otter`);
  }
  assert.doesNotMatch(readFileSync(new URL("ui/mobile.html", repo), "utf8"), /Cage/);
});

