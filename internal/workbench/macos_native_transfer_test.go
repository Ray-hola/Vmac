package workbench

import (
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"testing"

	"github.com/Ray-hola/Vmac/internal/guestos"
)

func TestMacOSNativeTransferNamesAndClipboardTypes(t *testing.T) {
	for _, name := range []string{"笔记.txt", "with spaces.txt", "it's.txt"} {
		if !validNativeUploadName(name) {
			t.Errorf("rejected valid file name %q", name)
		}
	}
	for _, name := range []string{"", ".", "..", "a/b", "a\\b", "a:b", "a\nb"} {
		if validNativeUploadName(name) {
			t.Errorf("accepted non-file-name %q", name)
		}
	}
	text := "clipboard"
	if !(nativeClipboardValue{Text: &text}).valid() || !(nativeClipboardValue{PNG: "png"}).valid() {
		t.Fatal("text and PNG should be accepted individually")
	}
	if (nativeClipboardValue{}).valid() || (nativeClipboardValue{Text: &text, PNG: "png"}).valid() {
		t.Fatal("expected exactly one clipboard representation")
	}
}

func TestMacOSNativeTransferRequiresTrustedLocalView(t *testing.T) {
	s := testServer(t)
	s.macosGuest = &guestos.MacOSProfile{Instance: "mac", User: "guestdev"}
	handler := s.handler()
	for _, path := range []string{"/api/macos/native-files", "/api/macos/native-upload", "/api/macos/native-clipboard", "/api/macos/native-drag-out", "/api/macos/input-sources"} {
		r := httptest.NewRequest("POST", s.origin+path, nil)
		r.AddCookie(&http.Cookie{Name: s.cookieName(), Value: s.session})
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != http.StatusForbidden && w.Code != http.StatusNotFound {
			t.Errorf("%s admitted untrusted request, status %d", path, w.Code)
		}
	}
}

func TestMacOSInputSourcesRouteIsAvailableInWorkbench(t *testing.T) {
	if !macOSWorkbenchRoute("/api/macos/input-sources") {
		t.Fatal("the macOS workbench must admit the input sources route")
	}
}

// A route registered for the macOS guest but missing from the workbench gate
// answers 409 to every caller, so the two lists must not drift apart.
func TestMacOSRegisteredRoutesAreAdmittedByWorkbench(t *testing.T) {
	source, err := os.ReadFile("server.go")
	if err != nil {
		t.Fatal(err)
	}
	block := regexp.MustCompile(`(?s)\tif s\.macosGuest != nil \{\n\t\tmux\.HandleFunc.*?\n\t\}\n`).Find(source)
	routes := regexp.MustCompile(`mux\.HandleFunc\("[A-Z]+ (/api/macos/[a-z0-9/-]+)"`).FindAllSubmatch(block, -1)
	if len(routes) < 10 {
		t.Fatalf("found only %d macOS routes in server.go", len(routes))
	}
	for _, route := range routes {
		if path := string(route[1]); !macOSWorkbenchRoute(path) {
			t.Errorf("%s is registered but refused by the macOS workbench gate", path)
		}
	}
}
