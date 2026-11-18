//go:build !darwin || !arm64 || !cgo || no_vz

package limaembed

import "errors"

var errNoEmbeddedHost = errors.New("no embedded macOS host")

func forwardEmbeddedHostagent([]string) error { return errNoEmbeddedHost }
