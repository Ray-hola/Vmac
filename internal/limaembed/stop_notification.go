package limaembed

import (
	"os"
	"path/filepath"

	"github.com/Ray-hola/Vmac/internal/host"
)

// One hostagent runs in this process. Buffering preserves cancellation that
// arrives while the driver and hostagent are still initializing.
var hostagentSignals = make(chan os.Signal, 1)

type embeddedHostagentKey struct{}

func notifyHostagentStop() { notifyEmbeddedStop(hostagentSignals) }

func notifyEmbeddedStop(stop chan os.Signal) {
	select {
	case stop <- os.Interrupt:
	default:
	}
}

func watchHostagentStop(socket string) (func(), error) {
	return host.ListenInstanceStop(filepath.Dir(socket), notifyHostagentStop)
}
