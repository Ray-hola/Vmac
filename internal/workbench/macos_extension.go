package workbench

import (
	"context"
	_ "embed"
	"errors"
	"strings"
	"time"

	"github.com/Ray-hola/Vmac/internal/guestos"
	"github.com/Ray-hola/Vmac/internal/version"
)

//go:embed macos_extension_probe.pl
var macOSProbeFSKit string

func (s *Server) checkMacOSSetupProjects(parent context.Context) error {
	ctx, cancel := context.WithTimeout(parent, 15*time.Second)
	defer cancel()
	check := s.probeMacOSFileSystemExtension
	if version.MacOSGuestOnly {
		check = s.verifyMacOSUploadOnly
	}
	err := check(ctx)
	s.mu.Lock()
	s.macSetupProjectsChecked = time.Time{}
	if err == nil {
		s.macSetupProjectsChecked = time.Now()
	}
	s.mu.Unlock()
	return err
}

func (s *Server) probeMacOSFileSystemExtension(ctx context.Context) error {
	probe := "exec /usr/bin/perl -"
	if s.macosGuest != nil && s.macosGuest.Backend == guestos.MacOSQEMU {
		probe += " server-readonly"
	}
	cmd := s.macOSSSHCommand(ctx, "-T", s.sshTarget(), "--", probe)
	cmd.Stdin = strings.NewReader(macOSProbeFSKit)
	if err := cmd.Run(); err != nil {
		return errors.New("macFUSE 的只读挂载测试未通过。请在客机中确认扩展已启用，然后运行统一检测")
	}
	return nil
}

func (s *Server) verifyMacOSUploadOnly(ctx context.Context) error {
	projects, err := s.projectPaths()
	if err != nil {
		return errors.New("无法读取已授权项目清单")
	}
	s.mu.Lock()
	activeShares := len(s.projectShares) + len(s.clientMounts)
	s.mu.Unlock()
	if len(projects) != 0 || activeShares != 0 {
		return errors.New("检测到宿主项目或共享连接。移除共享后再运行统一检测")
	}
	sharesConfined, _ := s.macOSVMLayout()
	if !sharesConfined {
		return errors.New("无法确认虚拟机配置未挂载宿主目录或额外磁盘")
	}
	const checkMounts = `mounts=$(/sbin/mount) || exit 1
printf '%s\n' "$mounts" | /usr/bin/awk -v root="$HOME/Cage/Projects" '
    index($0, " on " root " (") || index($0, " on " root "/") ||
    index($0, " on /run/cage-client-projects (") || index($0, " on /run/cage-client-projects/") { exit 1 }
'`
	if err := s.macOSSSHCommand(ctx, "-T", s.sshTarget(), "--", checkMounts).Run(); err != nil {
		return errors.New("无法确认客机项目目录没有活动挂载，请检查客机连接并重试")
	}
	return nil
}
