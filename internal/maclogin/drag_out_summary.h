// Which closing notice a drag out of the guest gets once its last item is
// written: 0 for "copied N items", 1 for an error. A single failed item makes
// it an error, so a later item that arrives cannot hide the failure.
static inline int cageDragOutSummary(unsigned long total, unsigned long failed) {
    (void)total;
    return failed > 0;
}
