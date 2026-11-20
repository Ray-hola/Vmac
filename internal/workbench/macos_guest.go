package workbench

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"al.essio.dev/pkg/shellescape"

	"github.com/Ray-hola/Vmac/internal/cage"
	"github.com/Ray-hola/Vmac/internal/guestos"
	"github.com/Ray-hola/Vmac/internal/host"
	"github.com/Ray-hola/Vmac/internal/managedproxy"
	"github.com/Ray-hola/Vmac/internal/paths"
	"github.com/Ray-hola/Vmac/internal/version"
)

// Only the trusted local workbench can operate the native Mac. Each route
// must have a native guest implementation or run entirely on the host.
func macOSWorkbenchRoute(path string) bool {
	if nativeWorkbenchRoute(path) {
		return true
	}
	if id, ok := strings.CutPrefix(path, "/api/input/files/desktop/"); ok {
		return id == "requests" || id == "open" || browserFileID.MatchString(id)
	}
	switch path {
	case "/api/macos/disk", "/api/macos/space/scan", "/api/macos/space/clean", "/api/environment/macos-screen-sharing", "/api/macos/first-setup", "/api/appearance/codex", "/api/macos/project-approval", "/api/macos/exit-policy", "/api/macos/login", "/api/macos/maintenance", "/api/macos/restart", "/api/macos/native-files", "/api/macos/native-upload", "/api/macos/native-clipboard", "/api/macos/native-reveal", "/api/macos/native-drop", "/api/macos/guest-admin":
		return true
	case "/api/macos/input-sources":
		return true
	}
	return strings.HasPrefix(path, "/api/macos/claude/") || strings.HasPrefix(path, "/api/macos-browser/")
}

func macOSInstanceRunning(instanceDir, backend string) bool {
	data, err := os.ReadFile(filepath.Join(instanceDir, "cage-running.json"))
	var record struct {
		PID     int    `json:"pid"`
		Started string `json:"started"`
	}
	if err != nil || json.Unmarshal(data, &record) != nil || record.PID < 1 {
		return false
	}
	if !processExists(record.PID) || !cage.ProcessStartMatches(record.PID, record.Started) {
		return false
	}
	if backend == guestos.MacOSQEMU {
		path := filepath.Join(instanceDir, "qemu.pid")
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() > 32 {
			return false
		}
		data, err := os.ReadFile(path)
		pid, parseErr := strconv.Atoi(strings.TrimSpace(string(data)))
		return err == nil && parseErr == nil && pid > 1 && processExists(pid)
	}
	return true
}

func (s *Server) macOSSSHCommand(ctx context.Context, args ...string) *exec.Cmd {
	base, err := guestos.MacOSSSHArgs(s.profile, s.macosGuest.User)
	if err != nil {
		return &exec.Cmd{Err: err}
	}
	cmd := exec.CommandContext(ctx, sshExecutable(), append(base, args...)...)
	cmd.Env = sshEnvironment()
	host.HideCommandWindow(cmd)
	return cmd
}

var errMacOSGuestSSH = errors.New("无法以已绑定的普通用户连接到这台虚拟 Mac，请检查客机身份和 SSH 登录")

func (s *Server) checkMacOSGuest(ctx context.Context) error {
	if !s.vmRunning() {
		return errors.New("macOS 客机尚未启动")
	}
	client, err := s.gateClient()
	if err != nil {
		return errors.New("无法验证 macOS 客机的网络隔离状态")
	}
	state, err := client.Status(ctx)
	if err != nil {
		return errors.New("无法验证 macOS 客机的网络门槛")
	}
	if state.Mode != cage.GateClosed {
		s.mu.Lock()
		ready, paused := s.ready, s.networkPaused
		s.mu.Unlock()
		reason := ""
		switch {
		case s.macSetupPending():
			reason = "首次系统设置期间外网关闭"
		case paused:
			reason = "网络保持暂停，请手动恢复后再联网"
		case !ready:
			reason = "客机重新连接，外网等待重新检查"
		default:
			cfg, cfgErr := loadConfig(s.configPath)
			if state.Mode != cage.GateOpen || cfgErr != nil || state.Report == nil || !time.Now().Before(state.Until) || state.Report.Authorizes(state.RunID, cfg.Fingerprint(), time.Now()) != nil {
				reason = "网络授权未通过当前配置的完整检查"
			}
		}
		if reason != "" {
			state, err = client.Close(ctx, reason)
			if err != nil || state.Mode != cage.GateClosed {
				return errors.New("macOS 客机网络状态不能确认")
			}
		}
	}
	s.publishGate(state)
	probe := `test "$(uname -s)" = Darwin && [[ $(sysctl -n hw.model) == VirtualMac* ]] && test "$(id -un)" = ` +
		shellescape.Quote(s.macosGuest.User) + ` && [[ " $(id -Gn) " != *" admin "* ]]`
	if s.macosGuest.Backend == guestos.MacOSQEMU {
		probe = `/usr/local/libexec/cage-guest-check --expect ` + shellescape.Quote(s.macosGuest.UUID) + ` && test "$(id -un)" = ` + shellescape.Quote(s.macosGuest.User) + ` && [[ " $(id -Gn) " != *" admin "* ]]`
	}
	if _, err := s.guest(ctx, probe); err != nil {
		var exit *exec.ExitError
		if errors.Is(ctx.Err(), context.DeadlineExceeded) || (errors.As(err, &exit) && exit.ExitCode() == 255) {
			return errMacOSGuestSSH
		}
		return errors.New("macOS 客机身份或普通账户校验未通过，请检查绑定的客机")
	}
	return nil
}

// macOSComponentReceiptProbe reads only the identity of the installed
// component receipt. Its file digests are checked by the explicit version view.
const macOSComponentReceiptProbe = `receipt=/var/db/cage-components.json
if ! test -e "$receipt"; then printf 'null'; exit 0; fi
exec /usr/local/libexec/cage-cli/bin/python3 -I -c '
import json, sys
try:
    with open(sys.argv[1]) as stream:
        value = json.load(stream)
    print(json.dumps({key: value.get(key) for key in ("protocol", "revision", "app_version", "system")}))
except (ValueError, AttributeError):
    print("null")
' "$receipt"`

var errMacOSComponentUpdate = errors.New("虚拟 Mac 的客机组件与当前 VMac 版本不一致，浏览器、剪贴板和声音可能无法连接。请保存工作后在环境设置中同步环境组件；系统磁盘、账户和项目数据会保留。")
var errMacOSAutomaticComponentSync = errors.New("客机组件自动同步失败，请在环境设置中重试")

// macOSComponentsDrifted reports whether a receipt read from the guest belongs
// to a different component kit. A missing or unreadable receipt also requires
// an update, matching the explicit version view.
func macOSComponentsDrifted(receipt []byte, required cage.GuestManifest) bool {
	var installed *struct {
		cage.GuestManifest
		System string `json:"system"`
	}
	if json.Unmarshal(receipt, &installed) != nil || installed == nil {
		return true
	}
	return installed.System != guestos.MacOS || installed.Protocol != required.Protocol || installed.Revision != required.Revision
}

// checkMacOSComponents runs once per connection. Without it a guest left on
// older components looks ready while its services fail, and every client
// retries those failures instead of offering the component update.
func (s *Server) checkMacOSComponents(ctx context.Context) error {
	kit, system := s.nativeComponentKit()
	required, err := guestos.RequiredNativeComponents(kit, system)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	receipt, err := s.guest(ctx, macOSComponentReceiptProbe)
	if err != nil {
		return fmt.Errorf("无法读取原客机的组件版本：%w", err)
	}
	drifted := macOSComponentsDrifted(receipt, required.GuestManifest)
	s.mu.Lock()
	s.macComponentsChecked = true
	s.guestUpdateRequired = drifted
	s.mu.Unlock()
	return nil
}

func (s *Server) attachMacOSGuest() error {
	return s.attachMacOSGuestForBoot(false)
}

func (s *Server) attachMacOSGuestForBoot(syncComponents bool) error {
	ctx, cancel := s.controlContext()
	err := s.checkMacOSGuest(ctx)
	cancel()
	s.mu.Lock()
	checkComponents := err == nil && !s.macComponentsChecked
	s.mu.Unlock()
	setupPending := s.macSetupPending()
	if checkComponents && !setupPending {
		if checkErr := s.checkMacOSComponents(s.operationContext()); syncComponents && checkErr != nil {
			s.mu.Lock()
			s.guestUpdateRequired = true
			s.mu.Unlock()
			err = fmt.Errorf("%w。%w", errMacOSAutomaticComponentSync, checkErr)
		}
	}
	if err == nil && syncComponents && !setupPending {
		s.mu.Lock()
		needsSync := s.macComponentsChecked && s.guestUpdateRequired
		s.mu.Unlock()
		if needsSync {
			if syncErr := s.syncNativeComponents(false); syncErr != nil {
				err = fmt.Errorf("%w。%w", errMacOSAutomaticComponentSync, syncErr)
			}
		}
	}
	// Component maintenance can outlast the initial SSH timeout.
	ctx, cancel = s.controlContext()
	defer cancel()
	if err == nil {
		err = s.syncNativeBrowserProfile(ctx)
	}
	if err == nil && syncComponents && !setupPending {
		s.configureMacOSChromeProfile(s.operationContext())
	}
	s.mu.Lock()
	if err != nil {
		s.macComponentsChecked = false
	}
	newlyReady := !s.ready && err == nil
	checkAfterReconnect := newlyReady && !s.closing && !s.networkPaused && !s.jobs.snapshot().Running &&
		!(version.MacOSGuestOnly && s.guestUpdateRequired)
	s.ready = err == nil
	s.guestUpdateError = ""
	if err != nil {
		s.guestUpdateError = err.Error()
	} else if s.guestUpdateRequired {
		s.guestUpdateError = errMacOSComponentUpdate.Error()
	}
	s.mu.Unlock()
	if newlyReady && !s.macSetupPending() {
		s.restoreProjectShares()
		if checkAfterReconnect {
			_, _ = s.submitJob("network-recovery", s.checkNetworkIfWanted)
		}
	} else if err == nil && !s.macSetupPending() {
		s.retryMacOSProjectShares(ctx)
	}
	return err
}

func (s *Server) macOSLifecycleCommand(action string) error {
	ctx, cancel := context.WithTimeout(s.operationContext(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.exe, "guest-os", "macos", action)
	cmd.Env = append(os.Environ(), cage.ConfigEnv+"="+s.configPath)
	job := s.jobs.execution()
	cmd.Stdout, cmd.Stderr = job, job
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("macOS 客机操作失败（%s）：%w", action, err)
	}
	return nil
}

func (s *Server) startMacOSGuest() error {
	starting := !s.vmRunning()
	if starting {
		if err := s.prepareMacOSStartupTimezone(s.operationContext()); err != nil {
			return err
		}
		if err := s.macOSLifecycleCommand("start"); err != nil {
			return err
		}
	}
	if err := s.syncMacGuestPassword(s.operationContext()); err != nil {
		return err
	}
	syncComponents := version.MacOSGuestOnly && starting
	err := s.attachMacOSGuestForBoot(syncComponents)
	if starting && macOSBootConnectionPending(err) {
		ctx, cancel := context.WithTimeout(s.operationContext(), 60*time.Second)
		defer cancel()
		s.setMessage("macOS 客机已启动，正在等待客机连接…")
		retry := time.NewTicker(2 * time.Second)
		defer retry.Stop()
		for macOSBootConnectionPending(err) {
			select {
			case <-ctx.Done():
				if errors.Is(ctx.Err(), context.Canceled) {
					return ctx.Err()
				}
				return err
			case <-retry.C:
				err = s.attachMacOSGuestForBoot(syncComponents)
			}
		}
	}
	if err != nil {
		return err
	}
	return s.checkNetworkIfWanted()
}

func macOSStartupTimezone(cfg cage.Config, location Location) string {
	zone := location.Timezone
	if zone == "" || zone == "Local" || macOSZone(zone) == macOSZone(cfg.Timezone) {
		return cfg.Timezone
	}
	if _, err := time.LoadLocation(zone); err != nil {
		return cfg.Timezone
	}
	observed := location.exitLocation()
	if state, _ := cfg.ExitPolicy.BindMissing(observed).Evaluate(location.IP, &observed); state != cage.CheckPassed {
		return cfg.Timezone
	}
	return zone
}

func (s *Server) prepareMacOSStartupTimezone(ctx context.Context) error {
	s.mu.Lock()
	automatic, paused, pauseVersion := s.preferences.AutoTimezone, s.networkPaused, s.safety.pauseVersion
	s.mu.Unlock()
	if !automatic || paused || s.macSetupPending() {
		return ctx.Err()
	}
	cfg, err := loadConfig(s.configPath)
	if err != nil {
		return err
	}
	store, err := managedproxy.Applied(s.profile, cfg.ProxyURL, cfg.ProxyRevision)
	if err != nil {
		return ctx.Err()
	}
	s.setMessage("正在查询代理出口的时区…")
	probeCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := s.ensureMacOSProxyRunning(probeCtx, store); err != nil {
		return ctx.Err()
	}
	location, err := probeLocation(probeCtx, cfg)
	if err != nil {
		return ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := s.finishLocationProbe(cfg, location, nil); err != nil {
		return err
	}
	zone := macOSStartupTimezone(cfg, location)
	if zone == cfg.Timezone {
		return nil
	}
	return s.applyMacOSStartupTimezone(ctx, cfg, zone, pauseVersion)
}

func (s *Server) applyMacOSStartupTimezone(ctx context.Context, cfg cage.Config, zone string, pauseVersion uint64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.networkPaused || s.safety.pauseVersion != pauseVersion || !s.preferences.AutoTimezone {
		return ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	current, err := loadConfig(s.configPath)
	if err != nil || current.Fingerprint() != cfg.Fingerprint() {
		return err
	}
	current.Timezone = zone
	return writePrivate(paths.VMacConfigPath(s.configPath), current)
}

// The guest browser bridge may come up after the SSH service.
func macOSBootConnectionPending(err error) bool {
	if errors.Is(err, errMacOSAutomaticComponentSync) {
		return false
	}
	return errors.Is(err, errMacOSGuestSSH) || errors.Is(err, errGuestBrowserDisconnected) || errors.Is(err, context.DeadlineExceeded)
}

func (s *Server) restartMacOSGuest(w http.ResponseWriter, r *http.Request) {
	if !s.hasTrustedView(r) || s.macosGuest == nil {
		http.Error(w, "请在本机 VMac 工作台重启 macOS 客机", http.StatusForbidden)
		return
	}
	s.launch(w, "restart", func() error {
		if s.vmRunning() {
			s.setMessage("正在关闭客机外网并停止 macOS 客机…")
			gateErr := s.closeProxyGate("macOS 客机正在重启")
			// Stopping the VM also cuts its network if the gate is unreachable.
			if err := s.stopEnvironment(); err != nil {
				return errors.Join(gateErr, err)
			}
		}
		if err := s.operationContext().Err(); err != nil {
			return err
		}
		s.setMessage("正在启动 macOS 客机并恢复连接…")
		return s.startEnvironment(false)
	})
}

//go:embed macos-locale.sh
var macOSLocaleScript string

func (s *Server) syncMacOSRegion(ctx context.Context, cfg cage.Config) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	s.setMessage("正在应用 macOS 客机账户的地区与语言…")
	locale := strings.TrimSuffix(cfg.Locale, ".UTF-8")
	cmd := shellescape.QuoteCommand([]string{"/bin/bash", "-c", macOSLocaleScript, "cage-locale", "NSGlobalDomain", locale})
	if _, err := s.guest(ctx, "exec "+cmd); err != nil {
		return fmt.Errorf("macOS 客机已启动，未能写入客机账户的地区与语言：%w", err)
	}
	s.setMessage("正在等候 macOS 客机读回已保存的时区与语言…")
	var last guestObservation
	for {
		got, err := s.macOSGuestObservation(ctx, map[string]any{"stage": "environment"})
		if err == nil {
			last = got
			if s.guestSettingsOK(got, cfg) {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			if errors.Is(ctx.Err(), context.Canceled) {
				return ctx.Err()
			}
			return fmt.Errorf("macOS 客机的时区和语言尚未全部生效。期望 %s、%s，系统读回时区 %q、地区 %q、首选语言 %q，进程读回 %q、%q。外网保持关闭。可稍后重检，时区持续不符时请停止并重新启动客机。", cfg.Timezone, cfg.Locale, last.SystemTimezone, last.SystemLocale, last.SystemLanguage, last.TZ, last.ProcessLocale)
		case <-time.After(time.Second):
		}
	}
}

func (s *Server) stopMacOSGuest() error {
	s.mu.Lock()
	s.ready = false
	s.macComponentsChecked = false
	s.macSetupProjectsChecked = time.Time{}
	s.macSetupSharingConfirmed = false
	s.macSetupSharingAttempt = time.Time{}
	s.macSetupSharingStatus = macOSScreenSharingStatus{}
	s.mu.Unlock()
	s.closeMacOSScreenSharing()
	s.closeWindowsBrowser()
	s.terminals.closeAll()
	s.closeProjectShares()
	return s.macOSLifecycleCommand("stop")
}
