package workbench

import (
	"encoding/json"
	"testing"
	"time"
)

func TestProxyTrafficRollingTotalsResetsAndRestart(t *testing.T) {
	base := time.Unix(1800000000, 0)
	var h trafficHistory
	if _, _, ok := h.observe(base, "core-a", 1000, 2000); ok {
		t.Fatal("first sample must establish a baseline")
	}
	up, down, ok := h.observe(base.Add(2*time.Second), "core-a", 1200, 2600)
	if !ok || up != 100 || down != 300 {
		t.Fatalf("rates %v %v %v", up, down, ok)
	}
	data, _ := json.Marshal(h)
	var restored trafficHistory
	_ = json.Unmarshal(data, &restored)
	restored.observe(base.Add(4*time.Second), "core-a", 1400, 2800)
	restored.observe(base.Add(6*time.Second), "core-b", 10, 20)
	var totalUp, totalDown int64
	for _, b := range restored.Buckets {
		totalUp += b.Up
		totalDown += b.Down
	}
	if totalUp != 410 || totalDown != 820 {
		t.Fatalf("restart/reset inflated totals: %d/%d", totalUp, totalDown)
	}
	restored.observe(base.Add(25*time.Hour), "core-c", 0, 0)
	if len(restored.Buckets) != 0 {
		t.Fatal("old buckets were not expired")
	}
}
func TestProxyTrafficUnavailableGapIsNotInstantaneousRate(t *testing.T) {
	base := time.Unix(1800000000, 0)
	var h trafficHistory
	h.observe(base, "core", 0, 0)
	if _, _, ok := h.observe(base.Add(time.Minute), "core", 100, 200); ok {
		t.Fatal("collection gap cannot be displayed as live speed")
	}
	if h.Buckets[0].Up != 100 {
		t.Fatal("valid delta after a gap should still enter the history")
	}
}

func TestProxyTrafficDoesNotBackfillUnknownDay(t *testing.T) {
	base := time.Unix(1800000000, 0)
	var h trafficHistory
	h.observe(base, "core", 100, 200)
	h.observe(base.Add(25*time.Hour), "core", 900000, 1000000)
	if len(h.Buckets) != 0 {
		t.Fatal("a counter gap older than the window cannot be attributed to the last 24 hours")
	}
}
