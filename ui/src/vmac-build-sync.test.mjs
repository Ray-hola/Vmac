import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

// desktop/Cage.swift uses the VMac shell, toolbar, toast and palette in every
// build, so each script that compiles it has to list those files as well.
const needed = ["desktop/VMacPalette.swift", "desktop/VMacShell.swift", "desktop/VMacToolbar.swift", "desktop/VMacToast.swift"];
const scripts = new URL("../../scripts/", import.meta.url);

test("every script that compiles the launcher lists the VMac sources", () => {
  const compiling = readdirSync(scripts).filter(name => name.endsWith(".sh"))
    .filter(name => readFileSync(new URL(name, scripts), "utf8").includes("desktop/Cage.swift"));
  assert.ok(compiling.includes("build-vmac.sh"), "the VMac build compiles the launcher");
  for (const name of compiling) {
    const source = readFileSync(new URL(name, scripts), "utf8");
    for (const file of needed) assert.ok(source.includes(file), `${name} is missing ${file}`);
  }
});
