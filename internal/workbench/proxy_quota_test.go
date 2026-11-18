package workbench

import (
	"testing"
	"time"
)

func TestSubscriptionQuota(t *testing.T) {
	q := parseTrafficQuota("upload=10; download=30; total=100; expire=42", time.Time{})
	if q == nil || q.Used != 40 || q.Remaining != 60 || q.UsedPercent != 40 {
		t.Fatalf("incorrect quota: %+v", q)
	}
	q = parseTrafficQuota("upload=100; download=30; total=100", time.Time{})
	if q == nil || q.Remaining != 0 || q.UsedPercent != 100 {
		t.Fatal("over-quota must clamp the bar")
	}
	for _, raw := range []string{"", "upload=0; total=100", "upload=-1; download=0; total=100", "upload=0; download=1; total=0", "upload=0; upload=10; download=0; total=100", "upload=18446744073709551615; download=1; total=100"} {
		if parseTrafficQuota(raw, time.Time{}) != nil {
			t.Fatalf("unknown/invalid quota became real: %s", raw)
		}
	}
}
