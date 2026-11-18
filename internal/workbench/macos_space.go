package workbench

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"time"

	"al.essio.dev/pkg/shellescape"
)

//go:embed space_engine.tar.gz
var spaceEngine []byte

func (s *Server) macOSSpace(w http.ResponseWriter, r *http.Request) {
	if !s.nativeMacOSTransferReady(w, r) {
		return
	}
	action := "scan"
	input := []byte{}
	if r.URL.Path == "/api/macos/space/clean" {
		action = "clean"
		var selection struct {
			Plan string   `json:"plan"`
			IDs  []string `json:"ids"`
		}
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 65536))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&selection) != nil || len(selection.Plan) != 32 || len(selection.IDs) == 0 || len(selection.IDs) > 1000 {
			http.Error(w, "请选择本次扫描中的项目", http.StatusBadRequest)
			return
		}
		if _, err := hex.DecodeString(selection.Plan); err != nil {
			http.Error(w, "无效清单", http.StatusBadRequest)
			return
		}
		input, _ = json.Marshal(selection)
	}
	ctx, cancel := context.WithTimeout(r.Context(), 115*time.Second)
	defer cancel()
	digest := sha256.Sum256(spaceEngine)
	revision := hex.EncodeToString(digest[:])[:20]
	// The only host-to-guest data here is the bundled engine. No host directories
	// are mounted, enumerated, or exposed to the guest.
	install := `set -eu
umask 077
base="$HOME/Library/Application Support/VMac Space Engine"
mkdir -p "$base"
dir="$base/` + revision + `"
if [ -x "$dir/vmac-space" ]; then cat >/dev/null; exit 0; fi
tmp=$(/usr/bin/mktemp -d "$base/.install.XXXXXXXX")
trap '/bin/rm -rf -- "$tmp"' EXIT
/usr/bin/tar -xzf - -C "$tmp"
[ -x "$tmp/vmac-space" ]
if [ ! -d "$dir" ]; then /bin/mv "$tmp" "$dir"; fi
`
	cmd := s.macOSSSHCommand(ctx, "-T", "cage-macos", "--", "/bin/sh -c "+shellescape.Quote(install))
	cmd.Stdin = bytes.NewReader(spaceEngine)
	if err := cmd.Run(); err != nil {
		http.Error(w, "客机空间引擎安装失败，请确认客机连接和可用空间", http.StatusBadGateway)
		return
	}
	command := `exec "$HOME/Library/Application Support/VMac Space Engine/` + revision + `/vmac-space" ` + action
	cmd = s.macOSSSHCommand(ctx, "-T", "cage-macos", "--", command)
	cmd.Stdin = bytes.NewReader(input)
	var output, stderr bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		message := stderr.String()
		if len(message) > 2000 {
			message = message[len(message)-2000:]
		}
		if message == "" {
			message = "客机连接中断或扫描超时，请重新扫描"
		}
		http.Error(w, message, http.StatusBadGateway)
		return
	}
	if !json.Valid(output.Bytes()) {
		http.Error(w, "客机返回的清单无效，请重新扫描", http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(output.Bytes())
}
