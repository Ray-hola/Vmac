package main

import (
	"github.com/Ray-hola/Vmac/internal/agentcli"
	"io"
)

func runAgent(args []string, stdin io.Reader, stdout io.Writer) int {
	return agentcli.Main(args, stdin, stdout)
}
