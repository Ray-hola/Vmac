import cageLogo from "./logo.png";
import vmacMark from "./vmac-mark.png";

// VMac shows its own mark; the shared workbench keeps the Cage logo.
export const logo = typeof window !== "undefined" && window.cageNativeVMWorkbench ? vmacMark : cageLogo;
