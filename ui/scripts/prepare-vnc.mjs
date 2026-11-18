import { cpSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
mkdirSync(".generated", { recursive: true });
cpSync("vendor/novnc", ".generated/novnc", { recursive: true, force: true });
execFileSync(
  "python3",
  ["../internal/cage/novnc-patch.py", ".generated/novnc"],
  { stdio: "inherit" },
);
