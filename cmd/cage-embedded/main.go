//go:build darwin && arm64 && cgo && !no_vz

// The AppKit launcher links this archive into its own executable.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"

	"github.com/Ray-hola/Vmac/internal/limaembed"
	_ "github.com/Ray-hola/Vmac/internal/maclogin"
)

//export cageStartEmbeddedVMHost
func cageStartEmbeddedVMHost(config *C.char) *C.char {
	env, err := limaembed.StartEmbeddedVMHost(C.GoString(config))
	if err != nil {
		env = map[string]string{"error": err.Error()}
	}
	data, err := json.Marshal(env)
	if err != nil {
		return nil
	}
	return C.CString(string(data))
}

func main() {}
