package workbench

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/Ray-hola/Vmac/internal/cage"
	"github.com/Ray-hola/Vmac/internal/guestos"
	"golang.org/x/crypto/ssh"
)

func macMaintenanceKit(t *testing.T) string {
	t.Helper()
	kit := filepath.Join(t.TempDir(), "guest-os")
	for _, name := range []string{"VMac Guest Window.app/Contents/MacOS/VMacGuestWindow", "VMac Guest Clipboard.app/Contents/MacOS/VMacGuestClipboard", "project/cage-sshfs", "project/cage-macos-terminal", "native-browser/macos-native-browser.mjs", "native-browser/macos-browser-service.mjs", "native-browser/macos-browser-window.mjs", "register-macos-browser.sh", "native-browser/macos-phone-browser.mjs", "macos-cli.py", "cli_channel.py"} {
		filename := filepath.Join(kit, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(filename), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filename, []byte("current"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return kit
}

func nativeMaintenanceRequest(s *Server, method, path, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, s.origin+path, strings.NewReader(body))
	r.Header.Set("Origin", s.origin)
	r.Header.Set("Content-Type", "application/json")
	r.AddCookie(&http.Cookie{Name: s.cookieName(), Value: s.session})
	r.AddCookie(&http.Cookie{Name: s.cookieName() + "-desktop", Value: trustedViewProof(s.token)})
	w := httptest.NewRecorder()
	s.handler().ServeHTTP(w, r)
	return w
}

func TestNativeVersionsUsesBoundTransportAndActualManifest(t *testing.T) {
	var mu sync.Mutex
	snapshot := nativeComponentSnapshot{}
	guest := newMacWorkspaceGuest(t, func(channel ssh.Channel, command string) (uint32, bool) {
		if !strings.Contains(command, "cage-components.json") {
			return 0, false
		}
		if !strings.Contains(command, "cage-cli/bin/python3") || !strings.Contains(command, "hashlib.file_digest") {
			t.Error("version read omitted the bundled Python and actual file verification")
			return 1, true
		}
		mu.Lock()
		defer mu.Unlock()
		if err := json.NewEncoder(channel).Encode(snapshot); err != nil {
			return 1, true
		}
		return 0, true
	})
	s := guest.s
	kit := macMaintenanceKit(t)
	s.exe = filepath.Join(filepath.Dir(kit), "cage")
	required, err := guestos.RequiredNativeComponents(kit, guestos.MacOS)
	if err != nil {
		t.Fatal(err)
	}
	check := func(status string, installed bool) {
		t.Helper()
		response := nativeMaintenanceRequest(s, "GET", "/api/environment/versions", "")
		var result struct {
			Components  componentVersions `json:"components"`
			Installed   bool              `json:"installed"`
			Tools       map[string]toolVersion
			Maintenance struct{ Native bool }
		}
		if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &result) != nil {
			t.Fatal(response.Code, response.Body.String())
		}
		if result.Components.Status != status || result.Installed != installed || !result.Maintenance.Native {
			t.Fatal(response.Body.String())
		}
		if status == "current" && result.Tools["claude"].Current != "2.1.311 (Claude Code)" {
			t.Fatal("tool version was inferred from required version")
		}
	}
	check("update_required", false)
	mu.Lock()
	snapshot.Manifest = &required.GuestManifest
	snapshot.Installed = true
	snapshot.Tools = map[string]string{"claude": "2.1.311 (Claude Code)"}
	mu.Unlock()
	check("current", true)
	mu.Lock()
	snapshot.Installed = false
	snapshot.Missing = []string{"/Applications/VMac Guest Clipboard.app/Contents/MacOS/VMacGuestClipboard"}
	mu.Unlock()
	check("update_required", false)
	if err = os.Remove(filepath.Join(kit, "macos-cli.py")); err != nil {
		t.Fatal(err)
	}
	check("unknown", false)
}

func TestStartedVMacSynchronizesOnlyAnOutdatedExistingGuest(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("uses a macOS test controller")
	}
	for _, tc := range []struct {
		name                       string
		boot, current, setup, fail bool
		wantSync                   bool
	}{
		{name: "cold boot with older components", boot: true, wantSync: true},
		{name: "already current", boot: true, current: true},
		{name: "attach to running guest"},
		{name: "first setup", boot: true, setup: true},
		{name: "installer failure", boot: true, fail: true, wantSync: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			kit := macMaintenanceKit(t)
			manifest, err := guestos.RequiredNativeComponents(kit, guestos.MacOS)
			if err != nil {
				t.Fatal(err)
			}
			attempt := filepath.Join(filepath.Dir(kit), "sync-attempt")
			g := newMacWorkspaceGuest(t, func(ch ssh.Channel, command string) (uint32, bool) {
				switch {
				case strings.Contains(command, "uname -s"):
					return 0, true
				case strings.Contains(command, "hashlib.file_digest"):
					_ = json.NewEncoder(ch).Encode(nativeComponentSnapshot{Manifest: &manifest.GuestManifest, Installed: true})
					return 0, true
				case strings.Contains(command, "cage-components.json"):
					receipt := manifest.GuestManifest
					if !tc.current {
						receipt.Revision = "older"
					}
					_ = json.NewEncoder(ch).Encode(struct {
						cage.GuestManifest
						System string `json:"system"`
					}{receipt, guestos.MacOS})
					return 0, true
				}
				return 0, false
			})
			s := g.s
			s.ready = false
			if tc.setup {
				s.macosGuest.SetupID = "pending"
			}
			s.exe = filepath.Join(filepath.Dir(kit), "vmac")
			exitCode := 0
			if tc.fail {
				exitCode = 1
			}
			script := fmt.Sprintf("#!/bin/sh\n[ \"$#\" = 5 ] && [ \"$1 $2 $3 $4\" = 'guest-os macos update-components --manifest' ] && [ -s \"$5\" ] || exit 2\nprintf attempted > %q\nexit %d\n", attempt, exitCode)
			if err = os.WriteFile(s.exe, []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			disk := filepath.Join(s.instanceDir(), "disk")
			if err = os.WriteFile(disk, []byte("existing disk"), 0600); err != nil {
				t.Fatal(err)
			}
			cfg, err := loadConfig(s.configPath)
			if err != nil {
				t.Fatal(err)
			}
			gate, err := cage.NewEgressGate(cfg)
			if err != nil {
				t.Fatal(err)
			}
			stopGate, err := cage.StartGateControl(s.configPath, s.instanceDir(), gate)
			if err != nil {
				t.Fatal(err)
			}
			defer stopGate()
			s.setJobForTest(Job{ID: "boot", Kind: "start", Running: true})
			err = s.attachMacOSGuestForBoot(tc.boot)
			if tc.fail {
				if !errors.Is(err, errMacOSAutomaticComponentSync) || macOSBootConnectionPending(err) || s.ready || !s.guestUpdateRequired {
					t.Fatalf("failed component sync was not surfaced: %v", err)
				}
			} else if err != nil || !s.ready || ((tc.boot || tc.setup) && s.guestUpdateRequired) {
				t.Fatalf("attach did not preserve readiness: %v", err)
			}
			if _, statErr := os.Stat(attempt); (statErr == nil) != tc.wantSync {
				t.Fatalf("update process: %v", statErr)
			}
			if data, err := os.ReadFile(disk); err != nil || string(data) != "existing disk" {
				t.Fatalf("original disk changed: %v", err)
			}
			if got := gate.Status().Mode; got != cage.GateClosed {
				t.Fatalf("gate opened early: %s", got)
			}
		})
	}
}

func TestNativeMaintenanceTransfersToExistingMacIdentity(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS maintenance executes the host OpenSSH and BSD tar")
	}
	var calls atomic.Int32
	var fail atomic.Bool
	var mu sync.Mutex
	files := map[string][]byte{}
	guest := newMacWorkspaceGuest(t, func(channel ssh.Channel, command string) (uint32, bool) {
		calls.Add(1)
		switch {
		case strings.Contains(command, "mktemp -d /private/var/tmp/cage-components."):
			if !strings.Contains(command, "cage") {
				t.Error("missing provisioning identity")
			}
			fmt.Fprintln(channel, "/private/var/tmp/cage-components.ABCDEFGH")
		case strings.Contains(command, "/usr/bin/tar -xf -"):
			archive := tar.NewReader(channel)
			for {
				header, err := archive.Next()
				if err == io.EOF {
					break
				}
				if err != nil {
					t.Error(err)
					return 1, true
				}
				if header.Typeflag == tar.TypeReg {
					contents, err := io.ReadAll(archive)
					if err != nil {
						t.Error(err)
						return 1, true
					}
					mu.Lock()
					files[strings.TrimPrefix(header.Name, "./")] = contents
					mu.Unlock()
				}
			}
			io.Copy(io.Discard, channel)
		case strings.Contains(command, "maintain-macos-workbench.sh"):
			if !strings.Contains(command, "cageuser components") || !strings.Contains(command, "/Users/cage/password") {
				t.Errorf("maintenance did not retain old provisioning/user identities: %s", command)
			}
			if fail.Load() {
				return 1, true
			}
		case strings.Contains(command, "/usr/sbin/chown -R root:wheel /private/var/tmp/cage-components.ABCDEFGH"),
			strings.Contains(command, "/bin/rm -rf /private/var/tmp/cage-components.ABCDEFGH"):
		default:
			t.Errorf("unexpected operation: %s", command)
			return 1, true
		}
		return 0, true
	})
	s := guest.s
	identifier := []byte("existing-mac-identity")
	if err := os.WriteFile(filepath.Join(s.instanceDir(), "vz-identifier"), identifier, 0600); err != nil {
		t.Fatal(err)
	}
	binding := guestos.MacOSProfile{Version: 1, Instance: "mac", User: "cageuser", MachineID: fmt.Sprintf("%x", sha256.Sum256(identifier))}
	if err := writePrivate(filepath.Join(s.profile, "macos-guest.json"), binding); err != nil {
		t.Fatal(err)
	}
	kit := macMaintenanceKit(t)
	manifest, err := guestos.RequiredNativeComponents(kit, guestos.MacOS)
	if err != nil {
		t.Fatal(err)
	}
	manifestFile := filepath.Join(t.TempDir(), "manifest.json")
	if err = guestos.WriteNativeComponentManifest(manifestFile, manifest); err != nil {
		t.Fatal(err)
	}
	var log bytes.Buffer
	for _, shouldFail := range []bool{true, false, false} {
		fail.Store(shouldFail)
		err = guestos.MaintainMacOSComponents(t.Context(), s.profile, kit, manifestFile, false, &log, &log)
		if (err != nil) != shouldFail {
			t.Fatal(err, log.String())
		}
	}
	mu.Lock()
	var transferred guestos.NativeComponentManifest
	err = json.Unmarshal(files["native-components.json"], &transferred)
	phone := string(files["native-browser/macos-phone-browser.mjs"])
	mu.Unlock()
	if err != nil || transferred.Revision != manifest.Revision || phone != "current" {
		t.Fatal("new capability or manifest missing from native transfer", err)
	}
	before := calls.Load()
	if err = os.WriteFile(filepath.Join(kit, "macos-cli.py"), []byte("changed"), 0600); err != nil {
		t.Fatal(err)
	}
	if guestos.MaintainMacOSComponents(t.Context(), s.profile, kit, manifestFile, false, &log, &log) == nil || calls.Load() != before {
		t.Fatal("changed source was transferred after manifest selection")
	}
}

func TestNativeMaintenanceRejectsLiveTerminalsBeforeJob(t *testing.T) {
	for _, system := range []string{guestos.MacOS, guestos.Windows11} {
		t.Run(system, func(t *testing.T) {
			s := testServer(t)
			if system == guestos.MacOS {
				s.macosGuest = &guestos.MacOSProfile{Instance: "mac", User: "cage"}
			} else {
				s.windowsGuest = &guestos.WindowsProfile{}
			}
			s.terminals.sessions = map[string]*terminalSession{"active": {}}
			for _, route := range []string{"/api/environment/update", "/api/environment/tools"} {
				response := nativeMaintenanceRequest(s, "POST", route, "{}")
				if response.Code != 409 || !strings.Contains(response.Body.String(), "结束正在运行的终端") || s.jobs.snapshot().Running {
					t.Fatal(response.Code, response.Body.String())
				}
			}
			s.terminals.sessions = nil
			response := nativeMaintenanceRequest(s, "POST", "/api/environment/update", "{}")
			if response.Code != 409 || !strings.Contains(response.Body.String(), "启动并登录客机") {
				t.Fatal(response.Code, response.Body.String())
			}
		})
	}
}
