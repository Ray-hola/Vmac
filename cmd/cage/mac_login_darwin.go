//go:build darwin && (amd64 || (arm64 && cgo && !no_vz))

package main

import _ "github.com/Ray-hola/Vmac/internal/maclogin"
