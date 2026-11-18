//go:build darwin && cage_macos_only

package workbench

import (
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
	if err := (&Server{}).ensureProjectShare(t.TempDir()); err == nil {
		t.Fatal("macOS-only build accepted a host project share")
	}
}
