package workbench

import (
	"context"
	"errors"
	"net/http"
	"os/exec"
	"strings"
	"time"

	"al.essio.dev/pkg/shellescape"
	"github.com/Ray-hola/Vmac/internal/diagnostics"
	"github.com/Ray-hola/Vmac/internal/guestos"
	"github.com/Ray-hola/Vmac/internal/host"
)

// The ordinary guest account may hold macOS administrator rights, so installers
// and System Settings accept its own name and password. The temporary setup
// administrator is still retired after the first setup; only the user the
// installer bound to this VM is ever added to or removed from the group.

func (s *Server) macOSGuestUser() (string, error) {
	if s.macosGuest == nil {
		return "", errors.New("当前不是 macOS 客机")
	}
	user := s.macosGuest.User
	if !guestos.ValidMacOSAccountName(user) {
		return "", errors.New("客机普通账户无效")
	}
	return user, nil
}

// macOSRootCommand runs a fixed argument vector as root through the VM's
// provisioning identity, whose sudo password stays inside the guest.
func (s *Server) macOSRootCommand(ctx context.Context, argv ...string) *exec.Cmd {
	user, err := guestos.MacOSProvisionUser(s.profile)
	if err != nil {
		return &exec.Cmd{Err: err}
	}
	args, err := guestos.MacOSSSHArgs(s.profile, user)
	if err != nil {
		return &exec.Cmd{Err: err}
	}
	op := shellescape.QuoteCommand(append([]string{"/usr/bin/sudo", "-S", "-p", ""}, argv...))
	cmd := exec.CommandContext(ctx, sshExecutable(), append(args, "-T", s.sshTarget(), "--", "exec "+op+` < "$HOME/password"`)...)
	cmd.Env = sshEnvironment()
	host.HideCommandWindow(cmd)
	return cmd
}

func (s *Server) macOSGuestIsAdmin(ctx context.Context) (bool, error) {
	user, err := s.macOSGuestUser()
	if err != nil {
		return false, err
	}
	out, err := s.macOSRootCommand(ctx, "/usr/sbin/dseditgroup", "-o", "checkmember", "-m", user, "admin").Output()
	text := string(out)
	switch {
	case strings.HasPrefix(text, "yes "):
		return true, nil
	case strings.HasPrefix(text, "no "):
		return false, nil
	case err != nil:
		return false, errors.New("无法读取客机账户权限，请确认客机已启动")
	default:
		return false, errors.New("客机返回了无法识别的账户权限")
	}
}

func (s *Server) setMacOSGuestAdmin(ctx context.Context, enabled bool) error {
	user, err := s.macOSGuestUser()
	if err != nil {
		return err
	}
	op := "-d"
	if enabled {
		op = "-a"
	}
	if out, err := s.macOSRootCommand(ctx, "/usr/sbin/dseditgroup", "-o", "edit", op, user, "-t", "user", "admin").CombinedOutput(); err != nil {
		_ = diagnostics.New(s.profile).Record("warn", "guest-admin", "dseditgroup failed: "+strings.TrimSpace(string(out)))
		return errors.New("修改客机管理员权限失败，请确认客机已启动并重试")
	}
	admin, err := s.macOSGuestIsAdmin(ctx)
	if err != nil {
		return err
	}
	if admin != enabled {
		return errors.New("客机管理员权限未生效，请稍后重试")
	}
	return nil
}

// grantMacOSGuestAdminAfterSetup runs once the temporary setup administrator
// has been retired, which still requires the ordinary account to be standard.
func (s *Server) grantMacOSGuestAdminAfterSetup() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := s.setMacOSGuestAdmin(ctx, true); err != nil {
		_ = diagnostics.New(s.profile).Record("warn", "guest-admin", "grant after setup: "+err.Error())
	}
}

func (s *Server) macOSGuestAdmin(w http.ResponseWriter, r *http.Request) {
	if s.macosGuest == nil {
		http.NotFound(w, r)
		return
	}
	if !s.vmRunning() || s.macSetupPending() {
		http.Error(w, "请先启动并完成 macOS 客机设置", http.StatusConflict)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	if r.Method == http.MethodPost {
		var input struct {
			Enabled *bool `json:"enabled"`
		}
		if !readJSON(w, r, &input) {
			return
		}
		if input.Enabled == nil {
			http.Error(w, "缺少管理员权限设置", http.StatusBadRequest)
			return
		}
		if err := s.setMacOSGuestAdmin(ctx, *input.Enabled); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
	}
	admin, err := s.macOSGuestIsAdmin(ctx)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	user, _ := s.macOSGuestUser()
	w.Header().Set("Cache-Control", "no-store")
	jsonReply(w, map[string]any{"user": user, "admin": admin})
}
