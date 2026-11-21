// Checks the rule in ../drag_out_summary.h. Run by scripts/test-maclogin-rules.sh.
#include <assert.h>
#include <stdio.h>
#include "../drag_out_summary.h"

int main(void) {
    // Every item arrived: the closing notice reports success.
    assert(cageDragOutSummary(1, 0) == 0);
    assert(cageDragOutSummary(3, 0) == 0);
    // One failed item is enough for the closing notice to be an error, even
    // when the last item written was fine.
    assert(cageDragOutSummary(3, 1) == 1);
    assert(cageDragOutSummary(3, 3) == 1);
    puts("drag out summary checks passed");
    return 0;
}
