//go:build darwin && cage_macos_only

package workbench

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMacOSOnlyRejectsOtherGuests(t *testing.T) {
	for _, system := range []string{"debian-13", "ubuntu-22.04", "windows-11"} {
		t.Run(system, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/api/start", strings.NewReader(`{"guest_system":"`+system+`"}`))
			request.Header.Set("Content-Type", "application/json")
			response := httptest.NewRecorder()
			(&Server{}).start(response, request)
			if response.Code != http.StatusConflict {
				t.Fatalf("starting %s returned %d", system, response.Code)
			}
			if canInstallCatalogLinux(system) {
				t.Fatalf("%s still appears in the Linux catalog", system)
			}
		})
	}
}

func TestMacOSOnlyRejectsRemoteWorkloads(t *testing.T) {
	gateway := &desktopGateway{generation: "test"}
	if candidate, err := gateway.prepare(switchRequest{Mode: "remote", ConnectionID: "test"}); candidate != nil || err == nil {
		t.Fatal("macOS-only build allowed a remote workload")
	}
}

func TestMacOSOnlyRejectsPersistentHostProject(t *testing.T) {
	s := testServer(t)
	s.ready = true
	body, err := json.Marshal(map[string]any{"workspace": t.TempDir(), "add": true, "activate": true})
	if err != nil {
		t.Fatal(err)
	}
	w := request(s, http.MethodPost, "/api/projects/open", s.origin, string(body), true)
	if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "主动上传") {
		t.Fatalf("project grant did not enforce upload-only isolation: %d %s", w.Code, w.Body.String())
	}
	projects, err := s.projectPaths()
	if err != nil || len(projects) != 0 || len(s.projectShares) != 0 || s.workspace() != "" {
		t.Fatalf("a rejected project grant changed workspace state: %v, %v", projects, err)
	}
}
