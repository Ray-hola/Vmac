// The Mac clipboard revision treated as already shared when the guest
// clipboard connection opens. The first connection of a launch starts from
// the current clipboard, so nothing copied before VMac showed the guest is
// sent. A later reconnection keeps the last shared revision: the connection
// closes whenever the guest is out of sight (another Space, a covered or
// minimized window), and what was copied on the Mac meanwhile must still be
// sent when the guest comes back.
static inline long cageClipboardBaseline(int connectedBefore, long sharedRevision, long currentRevision) {
    return connectedBefore ? sharedRevision : currentRevision;
}
