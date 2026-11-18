package workbench

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Ray-hola/Vmac/internal/managedproxy"
)

// Minute buckets bound storage and make the rolling total survive app/core restarts.
// They contain aggregate byte counts only, never destinations or connection details.
type trafficBucket struct {
	Minute int64 `json:"minute"`
	Up     int64 `json:"up"`
	Down   int64 `json:"down"`
}
type trafficHistory struct {
	Started int64           `json:"started"`
	Last    int64           `json:"last"`
	Core    string          `json:"core"`
	Up      int64           `json:"up"`
	Down    int64           `json:"down"`
	Buckets []trafficBucket `json:"buckets"`
}
type proxyTraffic struct {
	mu        sync.Mutex
	history   trafficHistory
	available bool
	rateReady bool
	upRate    float64
	downRate  float64
	updated   time.Time
}

func (h *trafficHistory) observe(now time.Time, core string, up, down int64) (float64, float64, bool) {
	if up < 0 || down < 0 {
		return 0, 0, false
	}
	stamp := now.UnixMilli()
	if h.Started == 0 {
		h.Started = stamp
	}
	previous := h.Last
	du, dd := int64(0), int64(0)
	valid := previous > 0 && stamp > previous && stamp-previous <= (24*time.Hour).Milliseconds()
	if valid {
		if core == h.Core {
			du, dd = up-h.Up, down-h.Down
			if du < 0 {
				du = up
			}
			if dd < 0 {
				dd = down
			}
		} else {
			du, dd = up, down
		}
	}
	cutoff := now.Add(-24*time.Hour).Unix() / 60
	kept := h.Buckets[:0]
	for _, b := range h.Buckets {
		if b.Minute > cutoff && b.Minute <= now.Unix()/60 {
			kept = append(kept, b)
		}
	}
	h.Buckets = kept
	if du > 0 || dd > 0 {
		minute := now.Unix() / 60
		if n := len(h.Buckets); n > 0 && h.Buckets[n-1].Minute == minute {
			h.Buckets[n-1].Up += du
			h.Buckets[n-1].Down += dd
		} else {
			h.Buckets = append(h.Buckets, trafficBucket{minute, du, dd})
		}
	}
	h.Last, h.Core, h.Up, h.Down = stamp, core, up, down
	// A long collection gap contributes to the total, but isn't an instantaneous rate.
	if !valid || stamp-previous > 10000 {
		return 0, 0, false
	}
	seconds := float64(stamp-previous) / 1000
	return float64(du) / seconds, float64(dd) / seconds, true
}
func (s *Server) proxyTrafficPath() string {
	return filepath.Join(managedproxy.Dir(s.profile), "traffic-history.json")
}
func (s *Server) sampleProxyTraffic(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	var counters struct {
		Up   int64 `json:"uploadTotal"`
		Down int64 `json:"downloadTotal"`
	}
	err := managedproxy.API(ctx, s.profile, "GET", "/connections", nil, &counters)
	now := time.Now()
	s.proxyTraffic.mu.Lock()
	defer s.proxyTraffic.mu.Unlock()
	if err != nil {
		s.proxyTraffic.available = false
		s.proxyTraffic.rateReady = false
		s.proxyTraffic.updated = now
		return
	}
	core := ""
	if info, e := os.Stat(managedproxy.Socket(s.profile)); e == nil {
		core = info.ModTime().UTC().Format(time.RFC3339Nano)
	}
	up, down, valid := s.proxyTraffic.history.observe(now, core, counters.Up, counters.Down)
	s.proxyTraffic.available = true
	s.proxyTraffic.rateReady = valid
	s.proxyTraffic.upRate = up
	s.proxyTraffic.downRate = down
	s.proxyTraffic.updated = now
}
func (s *Server) persistProxyTraffic() {
	s.proxyTraffic.mu.Lock()
	history := s.proxyTraffic.history
	// Marshal while holding the lock: buckets share their backing array.
	data, err := json.Marshal(history)
	s.proxyTraffic.mu.Unlock()
	if err != nil || history.Started == 0 {
		return
	}
	dir := filepath.Dir(s.proxyTrafficPath())
	if os.MkdirAll(dir, 0700) != nil {
		return
	}
	file, err := os.CreateTemp(dir, ".traffic-*")
	if err != nil {
		return
	}
	name := file.Name()
	defer os.Remove(name)
	if _, err = file.Write(data); err != nil {
		file.Close()
		return
	}
	if file.Close() != nil {
		return
	}
	_ = os.Rename(name, s.proxyTrafficPath())
}
func (s *Server) monitorProxyTraffic(ctx context.Context) {
	if data, err := os.ReadFile(s.proxyTrafficPath()); err == nil && len(data) < 256<<10 {
		var history trafficHistory
		if json.Unmarshal(data, &history) == nil && len(history.Buckets) <= 1441 {
			s.proxyTraffic.mu.Lock()
			s.proxyTraffic.history = history
			s.proxyTraffic.mu.Unlock()
		}
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	persist := time.NewTicker(time.Minute)
	defer persist.Stop()
	defer s.persistProxyTraffic()
	for {
		s.sampleProxyTraffic(ctx)
		select {
		case <-ctx.Done():
			return
		case <-persist.C:
			s.persistProxyTraffic()
		case <-ticker.C:
		}
	}
}
func (s *Server) proxyTrafficStatus(w http.ResponseWriter, r *http.Request) {
	var quota *trafficQuota
	if store, err := managedproxy.Load(s.profile); err == nil {
		for _, source := range store.Sources {
			for _, node := range source.Nodes {
				if node.ID == store.Selected {
					quota = parseTrafficQuota(source.Usage, source.Updated)
				}
			}
		}
	}
	now := time.Now()
	s.proxyTraffic.mu.Lock()
	defer s.proxyTraffic.mu.Unlock()
	t := &s.proxyTraffic
	available := t.available && now.Sub(t.updated) < 7*time.Second
	var up, down any
	if available && t.rateReady {
		up = t.upRate
		down = t.downRate
	}
	var totalUp, totalDown int64
	cutoff := now.Add(-24*time.Hour).Unix() / 60
	for _, b := range t.history.Buckets {
		if b.Minute > cutoff {
			totalUp += b.Up
			totalDown += b.Down
		}
	}
	jsonReply(w, map[string]any{"available": available, "upload_rate": up, "download_rate": down, "upload_24h": totalUp, "download_24h": totalDown, "recording_since": t.history.Started, "sampled_at": t.updated.UnixMilli(), "quota": quota})
}

type trafficQuota struct {
	Used        uint64    `json:"used"`
	Total       uint64    `json:"total"`
	Remaining   uint64    `json:"remaining"`
	UsedPercent float64   `json:"used_percent"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// Subscription headers describe the provider's accounting period, not the
// local rolling history. Missing/malformed values must stay unknown.
func parseTrafficQuota(raw string, updated time.Time) *trafficQuota {
	values := map[string]uint64{}
	for _, field := range strings.Split(raw, ";") {
		key, value, ok := strings.Cut(strings.TrimSpace(field), "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		if key != "upload" && key != "download" && key != "total" {
			continue
		}
		n, err := strconv.ParseUint(strings.TrimSpace(value), 10, 64)
		if err != nil {
			return nil
		}
		if _, duplicate := values[key]; duplicate {
			return nil
		}
		values[key] = n
	}
	u, up := values["upload"]
	d, down := values["download"]
	total := values["total"]
	if !up || !down || total == 0 || u > ^uint64(0)-d {
		return nil
	}
	used := u + d
	remaining := uint64(0)
	if used < total {
		remaining = total - used
	}
	percent := float64(used) / float64(total) * 100
	if percent > 100 {
		percent = 100
	}
	return &trafficQuota{used, total, remaining, percent, updated}
}
