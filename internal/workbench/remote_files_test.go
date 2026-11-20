package workbench

import (
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"testing"

	"github.com/Ray-hola/Vmac/internal/guestos"
)

// The native Mac window binds its clipboard file transfers to the local
// connection. A controller that keeps no connection contexts serves only its
// local workload, and a guest controller admits only the trusted local view,
// so the session must carry that view and the binding must succeed.
func TestLocalFileSessionBindsOnGuestAndLocalControllers(t *testing.T) {
	for _, macOS := range []bool{false, true} {
		s := testServer(t)
		s.remote = newRemoteGateway(s.profile)
		defer s.remote.manager.Close()
		if macOS {
			s.macosGuest = &guestos.MacOSProfile{Instance: "mac", User: "guestdev"}
		}
		jar, _ := cookiejar.New(nil)
		client := &controllerClient{origin: s.origin, record: controlFile{Token: s.token}, client: &http.Client{Jar: jar, Transport: browserTransport(func(r *http.Request) (*http.Response, error) {
			w := httptest.NewRecorder()
			s.handler().ServeHTTP(w, r)
			return w.Result(), nil
		})}}
		client.launch.URL = s.origin + "/#" + s.issueTicket()
		if err := client.openFileSession("local"); err != nil {
			t.Errorf("macOS=%t: openFileSession(local): %v", macOS, err)
			continue
		}
		// The transfer that follows is admitted past the session and view gates.
		if status, err := client.call("DELETE", "/api/clipboard/files/missing", nil, nil); err != nil || status == 401 || status == 403 || status == 409 {
			t.Errorf("macOS=%t: transfer after the session answered %d, %v", macOS, status, err)
		}
	}
}
