//go:build darwin && arm64 && cgo && !no_vz

package limaembed

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestEmbeddedHostStopWaitsForExplicitCommand(t *testing.T) {
	reader, writer := io.Pipe()
	go func() { _ = json.NewEncoder(writer).Encode(embeddedLaunch{Config: "test"}) }()
	decoder := json.NewDecoder(reader)
	var launch embeddedLaunch
	if err := decoder.Decode(&launch); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		var command string
		_ = decoder.Decode(&command)
		close(done)
	}()
	select {
	case <-done:
		t.Fatal("initial JSON newline prematurely stopped the guest")
	case <-time.After(20 * time.Millisecond):
	}
	_ = json.NewEncoder(writer).Encode("stop")
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stop command was not delivered")
	}
	reader.Close()
	writer.Close()
}

func TestEmbeddedHostRejectsOtherInstancesAndArguments(t *testing.T) {
	profile := t.TempDir()
	state := filepath.Join(profile, "state")
	home := filepath.Join(state, "lima")
	instance := filepath.Join(home, "mac")
	if err := os.MkdirAll(instance, 0700); err != nil {
		t.Fatal(err)
	}
	config := filepath.Join(profile, "config.json")
	launch := embeddedLaunch{
		State: state, LimaHome: home,
		Args: []string{"hostagent", "--pidfile", filepath.Join(instance, "ha.pid"), "--socket", filepath.Join(instance, "ha.sock"), "--run-gui", "mac"},
	}
	if _, err := embeddedInstanceDirectory(launch, config); err != nil {
		t.Fatal(err)
	}
	for _, flag := range []string{"--guestagent", "--nerdctl-archive", "--anything"} {
		copy := launch
		copy.Args = append(append([]string{}, launch.Args[:len(launch.Args)-1]...), flag, "/tmp/unowned", "mac")
		if _, err := embeddedInstanceDirectory(copy, config); err == nil {
			t.Errorf("accepted %s", flag)
		}
	}
	launch.Args[len(launch.Args)-1] = "other"
	if _, err := embeddedInstanceDirectory(launch, config); err == nil {
		t.Fatal("accepted other instance")
	}
}

func TestEmbeddedForwarderOnlyInterceptsMacHostagent(t *testing.T) {
	t.Setenv(embeddedSocketEnv, "")
	if err := forwardEmbeddedHostagent([]string{"hostagent", "mac"}); err != errNoEmbeddedHost {
		t.Fatal(err)
	}
	t.Setenv(embeddedSocketEnv, filepath.Join(t.TempDir(), "missing.sock"))
	if err := forwardEmbeddedHostagent([]string{"hostagent", "other"}); err != errNoEmbeddedHost {
		t.Fatal(err)
	}
	if err := forwardEmbeddedHostagent([]string{"hostagent", "mac"}); err == nil || !strings.Contains(err.Error(), "未连接") {
		t.Fatal(err)
	}
}
