package workbench

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/Ray-hola/Vmac/internal/host"
	"github.com/Ray-hola/Vmac/internal/managedproxy"
	"github.com/Ray-hola/Vmac/internal/paths"
)

// MigrateVMacHome changes the directory name in place. A virtual disk is not
// copied or modified. The destination must be empty and no old controller or
// guest may be using the source.
func MigrateVMacHome(home string) (returned error) {
	if !filepath.IsAbs(home) {
		return errors.New("无法识别 VMac 主目录")
	}
	old := filepath.Join(home, ".claude-cage")
	next := filepath.Join(home, ".vmac")
	oldDownloads, nextDownloads := old+"-downloads", next+"-downloads"
	info, err := os.Lstat(old)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil || !info.IsDir() || info.Mode().Perm()&077 != 0 {
		return errors.New("旧 VMac 目录不是私有的普通目录")
	}
	if err := host.CheckPrivateFile(filepath.Join(old, "macos-guest.json")); err != nil {
		return errors.New("未识别到原来的 VMac macOS 客机")
	}
	for _, destination := range []string{next, nextDownloads} {
		if _, err := os.Lstat(destination); !os.IsNotExist(err) {
			return errors.New("新的 VMac 路径已有数据，保留两边目录以免覆盖")
		}
	}
	profiles := []string{old}
	slots, err := os.ReadDir(filepath.Join(old, "vms"))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	for _, slot := range slots {
		if !slot.IsDir() {
			continue
		}
		target := filepath.Join(next, "vms", slot.Name())
		if _, vm := paths.VMacRoot(target); vm {
			profiles = append(profiles, filepath.Join(old, "vms", slot.Name()))
		}
	}

	type pathRewrite struct {
		path          string
		before, after []byte
	}
	var edits []pathRewrite
	for _, profile := range profiles {
		for _, controller := range []string{profile, filepath.Join(profile, "desktop-entry")} {
			if info, err := os.Lstat(controller); os.IsNotExist(err) {
				continue
			} else if err != nil || !info.IsDir() {
				return errors.New("旧控制服务目录不是普通目录")
			}
			lock, err := openControllerLock(controller, os.O_CREATE|os.O_RDWR)
			if err != nil {
				return err
			}
			defer lock.Close()
			if err := lockControllerForStart(lock); err != nil {
				return errors.New("请关闭旧 VMac 后再迁移")
			}
		}
		if macOSInstanceRunning(filepath.Join(profile, "state", "lima", "mac"), "") {
			return errors.New("旧 macOS 客机仍在运行，磁盘未移动")
		}
		if err := managedproxy.Stop(profile); err != nil {
			return err
		}
		for _, leaf := range []string{"environment.json", "state/lima/mac/ssh.config"} {
			source := filepath.Join(profile, leaf)
			if _, err := os.Lstat(source); os.IsNotExist(err) {
				continue
			}
			if err := host.CheckPrivateFile(source); err != nil {
				return err
			}
			data, err := os.ReadFile(source)
			if err != nil {
				return err
			}
			updated := strings.NewReplacer(oldDownloads, nextDownloads, old+"/", next+"/").Replace(string(data))
			if updated == string(data) {
				continue
			}
			relative, err := filepath.Rel(old, source)
			if err != nil {
				return err
			}
			edits = append(edits, pathRewrite{filepath.Join(next, relative), data, []byte(updated)})
		}
	}
	if info, err := os.Lstat(oldDownloads); err == nil && !info.IsDir() {
		return errors.New("旧下载目录不是普通目录，原目录已保留")
	} else if err != nil && !os.IsNotExist(err) {
		return err
	}

	binding := fmtAccountBinding(filepath.Join(old, "account.json"))
	if err := os.Rename(old, next); err != nil {
		return err
	}
	movedDownloads := false
	written := 0
	marker := filepath.Join(next, "account-device-binding")
	markerWritten := false
	defer func() {
		if returned == nil {
			return
		}
		if markerWritten {
			_ = os.Remove(marker)
		}
		for i := written - 1; i >= 0; i-- {
			returned = errors.Join(returned, managedproxy.Write(edits[i].path, edits[i].before))
		}
		if movedDownloads {
			returned = errors.Join(returned, os.Rename(nextDownloads, oldDownloads))
		}
		returned = errors.Join(returned, os.Rename(next, old))
	}()
	if _, err := os.Lstat(oldDownloads); err == nil {
		if err := os.Rename(oldDownloads, nextDownloads); err != nil {
			return err
		}
		movedDownloads = true
	} else if !os.IsNotExist(err) {
		return err
	}
	for _, edit := range edits {
		if err := managedproxy.Write(edit.path, edit.after); err != nil {
			return fmt.Errorf("未能迁移 VMac 的路径记录：%w", err)
		}
		written++
	}
	f, err := os.OpenFile(marker, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	markerWritten = true
	_, err = f.WriteString(binding)
	return errors.Join(err, f.Close())
}
