package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path"
	"strconv"
	"strings"
	"time"
	"unicode"

	"al.essio.dev/pkg/shellescape"
	"github.com/Ray-hola/Vmac/internal/version"
)

func (s *Server) nativeMacOSTransferReady(w http.ResponseWriter, r *http.Request) bool {
	if !version.MacOSGuestOnly || s.macosGuest == nil || !s.hasTrustedView(r) {
		http.NotFound(w, r)
		return false
	}
	s.mu.Lock()
	ready := s.ready && !s.closing
	s.mu.Unlock()
	if !ready {
		http.Error(w, "请先连接并登录客机", http.StatusConflict)
	}
	return ready
}

func validNativeUploadName(name string) bool {
	return len(name) > 0 && len(name) <= 255 && name != "." && name != ".." &&
		path.Base(name) == name && !strings.ContainsAny(name, ":\\") &&
		strings.IndexFunc(name, unicode.IsControl) < 0
}

func (s *Server) macOSNativeUpload(w http.ResponseWriter, r *http.Request) {
	if !s.nativeMacOSTransferReady(w, r) {
		return
	}
	name := r.URL.Query().Get("name")
	const limit = 1 << 30
	if !validNativeUploadName(name) || r.ContentLength > limit {
		http.Error(w, "文件名无效或文件超过 1 GB", http.StatusBadRequest)
		return
	}
	body := http.MaxBytesReader(w, r.Body, limit)
	file, err := os.CreateTemp("", "cage-native-upload-*")
	if err != nil {
		http.Error(w, "无法暂存上传文件", http.StatusInternalServerError)
		return
	}
	defer os.Remove(file.Name())
	defer file.Close()
	size, err := io.Copy(file, body)
	if err != nil {
		http.Error(w, "上传中断或文件超过 1 GB", http.StatusBadRequest)
		return
	}
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		http.Error(w, "无法读取上传文件", http.StatusInternalServerError)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 110*time.Second)
	defer cancel()
	// Every transfer gets a private directory. Remove incomplete uploads and
	// publish the original name only after the transfer terminates cleanly.
	script := `set -eu
umask 077
root="$HOME/Downloads/VMac Uploads"
mkdir -p -- "$root"
dir=$(/usr/bin/mktemp -d "$root/Upload.XXXXXXXX")
trap '/bin/rm -rf -- "$dir"' EXIT
tmp=$(/usr/bin/mktemp "$dir/.partial.XXXXXXXX")
/bin/cat > "$tmp"
[ "$(/usr/bin/stat -f %z "$tmp")" = "$2" ]
/bin/mv -- "$tmp" "$dir/$1"
trap - EXIT`
	command := "exec /bin/sh -c " + shellescape.Quote(script) + " upload " + shellescape.Quote(name) + " " + strconv.FormatInt(size, 10)
	cmd := s.macOSSSHCommand(ctx, "-T", "cage-macos", "--", command)
	cmd.Stdin = file
	if err := cmd.Run(); err != nil {
		http.Error(w, "客机未能保存文件，请检查连接和可用磁盘空间", http.StatusBadGateway)
		return
	}
	jsonReply(w, map[string]string{"folder": "Downloads/VMac Uploads"})
}

type nativeClipboardValue struct {
	Text *string `json:"text,omitempty"`
	PNG  string  `json:"png,omitempty"`
}

func (v nativeClipboardValue) valid() bool {
	return (v.Text != nil && len(*v.Text) <= 2<<20 && v.PNG == "") ||
		(v.Text == nil && v.PNG != "" && len(v.PNG) <= 12<<20)
}

func (s *Server) macOSNativeClipboard(w http.ResponseWriter, r *http.Request) {
	if !s.nativeMacOSTransferReady(w, r) {
		return
	}
	var input struct {
		Operation string `json:"operation"`
		nativeClipboardValue
	}
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 13<<20))
	d.DisallowUnknownFields()
	if d.Decode(&input) != nil || (input.Operation != "read" && (input.Operation != "write" || !input.nativeClipboardValue.valid())) {
		http.Error(w, "剪贴板只支持文字和 PNG 图片", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	cmd, _, err := s.clipboardCommand(ctx, "request", clipboardFileSelection{})
	if err != nil {
		http.Error(w, "无法连接客机剪贴板", http.StatusBadGateway)
		return
	}
	data, _ := json.Marshal(input)
	cmd.Stdin = bytes.NewReader(append(data, '\n'))
	out, err := cmd.StdoutPipe()
	if err != nil || cmd.Start() != nil {
		http.Error(w, "无法连接客机剪贴板", http.StatusBadGateway)
		return
	}
	data, readErr := io.ReadAll(io.LimitReader(out, 13<<20))
	out.Close()
	if err := cmd.Wait(); err != nil || readErr != nil {
		http.Error(w, "客机剪贴板暂不可用，请先解锁客机", http.StatusConflict)
		return
	}
	if input.Operation == "write" {
		jsonReply(w, map[string]bool{"ok": true})
		return
	}
	var result nativeClipboardValue
	if json.Unmarshal(data, &result) != nil || !result.valid() {
		http.Error(w, "客机剪贴板没有可传输的文字或图片", http.StatusBadRequest)
		return
	}
	jsonReply(w, result)
}

// The file navigation entry opens Finder inside the bound guest.
func (s *Server) macOSNativeFiles(w http.ResponseWriter, r *http.Request) {
	if !s.nativeMacOSTransferReady(w, r) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	if _, err := s.guest(ctx, `/usr/bin/open "$HOME"`); err != nil {
		http.Error(w, "无法打开客机文件管理，请确认客机已解锁", http.StatusBadGateway)
		return
	}
	jsonReply(w, map[string]bool{"opened": true})
}
