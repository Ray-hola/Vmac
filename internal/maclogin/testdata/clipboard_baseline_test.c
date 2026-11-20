// Checks the rule in ../clipboard_baseline.h. Run by scripts/test-maclogin-rules.sh.
#include <assert.h>
#include <stdio.h>
#include "../clipboard_baseline.h"

int main(void) {
    // First connection of a launch: what is already on the Mac clipboard is not sent.
    assert(cageClipboardBaseline(0, 0, 41) == 41);
    // Reconnection: the last shared revision is kept, so a copy made while
    // the guest was out of sight (41 -> 42) still counts as new.
    assert(cageClipboardBaseline(1, 41, 42) == 41);
    // Reconnection with nothing new stays in step.
    assert(cageClipboardBaseline(1, 42, 42) == 42);
    puts("clipboard baseline checks passed");
    return 0;
}
