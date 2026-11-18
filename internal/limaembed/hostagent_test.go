package limaembed

import (
	"os"
	"strings"
	"testing"
)

// The copy of limactl's hostagent command differs from it only as its
// header says: after a Lima upgrade, copy it again.
func TestHostagentCopy(t *testing.T) {
	upstream, err := os.ReadFile("../../third_party/lima/cmd/limactl/hostagent.go")
	if err != nil {
		t.Fatal(err)
	}
	ours, err := os.ReadFile("hostagent.go")
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Replace(string(upstream), "package main", "package limaembed", 1)
	want = strings.Replace(want, "WrapArgsError(cobra.ExactArgs(1))", "cobra.ExactArgs(1)", 1)
	want = strings.Replace(want, "signalCh := make(chan os.Signal, 1)", "signalCh := hostagentSignals", 1)
	want = strings.Replace(want, "ctx := cmd.Context()", "ctx := cmd.Context()\n\tembedded, _ := ctx.Value(embeddedHostagentKey{}).(*embeddedHostagent)\n\tpid := os.Getpid()\n\tif embedded != nil {\n\t\tpid = embedded.pid\n\t}", 1)
	want = strings.Replace(want, "store.WritePIDFile(pidfile, os.Getpid())", "store.WritePIDFile(pidfile, pid)", 1)
	want = strings.Replace(want, "if runGUI {", "if runGUI && embedded == nil {", 1)
	want = strings.Replace(want, "signal.Notify(signalCh, os.Interrupt, syscall.SIGTERM)", "if embedded != nil {\n\t\tsignalCh = embedded.stop\n\t} else {\n\t\tsignal.Notify(signalCh, os.Interrupt, syscall.SIGTERM)\n\t\tdefer signal.Stop(signalCh)\n\t}\n\tstopNotification, err := watchHostagentStop(socket)\n\tif err != nil {\n\t\treturn err\n\t}\n\tdefer stopNotification()", 1)
	// Our header: the comment block after the license lines.
	got := string(ours)
	start := strings.Index(got, "// Copied from")
	end := strings.Index(got, "package limaembed")
	if start < 0 || end < start {
		t.Fatal("hostagent.go lost its header")
	}
	got = got[:start] + got[end:]
	if got != want {
		t.Error("hostagent.go differs from third_party/lima/cmd/limactl/hostagent.go beyond its header: copy it again")
	}
}
