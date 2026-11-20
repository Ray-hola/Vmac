const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const support = path.join(os.homedir(), "Library", "Application Support");
const managed = path.join(support, "Cage", "Browser");
const stock = path.join(support, "Google", "Chrome");
const props = file => fs.lstatSync(file, { throwIfNoEntry: false });

function configureChrome() {
  if (!props(managed)?.isDirectory() || !props(path.join(managed, "Local State"))?.isFile()) return "uninitialized";
  // Ordinary Chrome uses the system keychain. An older mock-keychain profile
  // has to stay on its existing launch path to keep its saved logins readable.
  if (!props(path.join(managed, ".system-keychain"))?.isFile()) return "legacy-keychain";
  const existing = props(stock);
  if (existing?.isSymbolicLink() && fs.readlinkSync(stock) === managed) return "configured";
  if (existing && !existing.isDirectory()) throw new Error("unexpected Chrome profile path");

  const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const commands = execFileSync("/bin/ps", ["-axww", "-o", "command="], { encoding: "utf8" });
  if (commands.split("\n").map(line => line.trimStart()).some(line => line === chrome || line.startsWith(chrome + " "))) return "chrome-running";

  fs.mkdirSync(path.dirname(stock), { recursive: true, mode: 0o700 });
  const backup = existing ? path.join(fs.mkdtempSync(path.join(path.dirname(stock), "Chrome-before-VMac-")), "Chrome") : "";
  if (backup) fs.renameSync(stock, backup);
  try {
    fs.symlinkSync(managed, stock, "dir");
  } catch (error) {
    if (backup && !props(stock)) fs.renameSync(backup, stock);
    throw error;
  }
  return "configured";
}

process.stdout.write(configureChrome() + "\n");
