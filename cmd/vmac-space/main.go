// vmac-space runs inside the macOS guest. It never accepts a host path or an
// arbitrary deletion path: execution accepts IDs from a private, expiring plan.
package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

type item struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Path        string `json:"path"`
	Category    string `json:"category"`
	Bytes       int64  `json:"bytes"`
	Files       int    `json:"files"`
	Blocked     string `json:"blocked,omitempty"`
	Fingerprint string `json:"fingerprint,omitempty"`
	Parent      string `json:"parent,omitempty"`
}
type plan struct {
	ID        string    `json:"id"`
	Created   time.Time `json:"created_at"`
	Capacity  uint64    `json:"capacity"`
	Available uint64    `json:"available"`
	Items     []item    `json:"items"`
	Warnings  []string  `json:"warnings"`
	Engine    string    `json:"engine"`
}
type selection struct {
	Plan string   `json:"plan"`
	IDs  []string `json:"ids"`
}
type result struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Trashed bool   `json:"trashed"`
	Error   string `json:"error,omitempty"`
}

func token() string {
	var b [16]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b[:])
}
func stateDir(home string) string {
	return filepath.Join(home, "Library", "Application Support", "VMac Space")
}
func allowed(home, path string) bool {
	if filepath.Clean(path) != path || strings.ContainsAny(path, "\x00\r\n") {
		return false
	}
	for _, kind := range []string{"Caches", "Logs"} {
		parent := filepath.Join(home, "Library", kind)
		if filepath.Dir(path) == parent && filepath.Base(path) != "." && !strings.HasPrefix(strings.ToLower(filepath.Base(path)), "com.apple.") {
			return true
		}
	}
	return false
}
func canonical(path string) bool {
	resolved, e := filepath.EvalSymlinks(path)
	return e == nil && resolved == path
}
func parentIdentity(path string) (string, error) {
	info, e := os.Lstat(filepath.Dir(path))
	if e != nil {
		return "", e
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", errors.New("无法识别文件系统")
	}
	return fmt.Sprintf("%d:%d", st.Dev, st.Ino), nil
}

// A bounded complete inventory rejects links, mount points, special files and
// changes since review. Permission/timeout is unknown, never a zero-byte success.
func inventory(ctx context.Context, path string) (int64, int, string, error) {
	info, e := os.Lstat(path)
	if e != nil {
		return 0, 0, "", e
	}
	root := info.Sys().(*syscall.Stat_t)
	hash := sha256.New()
	var bytes int64
	count := 0
	seen := map[uint64]bool{}
	err := filepath.WalkDir(path, func(p string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		count++
		if count > 50000 {
			return errors.New("项目过大，请在客机内手动管理")
		}
		info, e := d.Info()
		if e != nil {
			return e
		}
		st := info.Sys().(*syscall.Stat_t)
		if st.Dev != root.Dev || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() && !info.Mode().IsRegular() {
			return errors.New("包含链接、挂载卷或特殊文件，已保留")
		}
		fmt.Fprintf(hash, "%q:%d:%d:%d:%d:%d:%d:%d\n", p, st.Dev, st.Ino, info.Size(), info.ModTime().UnixNano(), st.Ctimespec.Nano(), st.Mode, st.Nlink)
		if info.Mode().IsRegular() && !seen[st.Ino] {
			bytes += st.Blocks * 512
			seen[st.Ino] = true
		}
		return nil
	})
	return bytes, count, hex.EncodeToString(hash.Sum(nil)), err
}
func mole(ctx context.Context, root, action, path string) error {
	cmd := exec.CommandContext(ctx, "/bin/bash", filepath.Join(root, "guard.sh"), action, path)
	cmd.Env = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + os.Getenv("HOME"), "TERM=dumb", "NO_COLOR=1", "CI=1", "MOLE_DELETE_MODE=trash", "MOLE_DRY_RUN=0", "MO_NO_OPLOG=1", "MOLE_TEST_NO_AUTH=1"}
	if action == "trash" {
		cmd.Env[len(cmd.Env)-1] = "MOLE_TEST_NO_AUTH=0"
	}
	output, e := cmd.CombinedOutput()
	if e != nil {
		if ctx.Err() != nil {
			return errors.New("Mole 检查超时或连接中断，已保留")
		}
		message := strings.TrimSpace(string(output))
		if len(message) > 500 {
			message = message[len(message)-500:]
		}
		return fmt.Errorf("Mole 已保留：%s", message)
	}
	return nil
}
func scan(ctx context.Context, home, root string) (plan, error) {
	p := plan{ID: token(), Created: time.Now(), Items: []item{}, Warnings: []string{}, Engine: "Mole 1.60.0 · 安全检查 / 逐项移入废纸篓"}
	var disk syscall.Statfs_t
	if e := syscall.Statfs(home, &disk); e == nil {
		p.Capacity = disk.Blocks * uint64(disk.Bsize)
		p.Available = disk.Bavail * uint64(disk.Bsize)
	} else {
		p.Warnings = append(p.Warnings, "磁盘容量暂不可读")
	}
	for _, kind := range []string{"Caches", "Logs"} {
		folder := filepath.Join(home, "Library", kind)
		if !canonical(folder) {
			p.Warnings = append(p.Warnings, kind+" 路径不可访问或含链接，未扫描")
			continue
		}
		entries, e := os.ReadDir(folder)
		if e != nil {
			p.Warnings = append(p.Warnings, kind+" 权限不足，未扫描")
			continue
		}
		for _, entry := range entries {
			path := filepath.Join(folder, entry.Name())
			row := item{ID: token(), Name: entry.Name(), Path: path, Category: map[string]string{"Caches": "应用缓存", "Logs": "应用日志"}[kind]}
			if ctx.Err() != nil {
				p.Warnings = append(p.Warnings, "扫描已达到时间上限，剩余项目未扫描")
				break
			}
			if !allowed(home, path) || !canonical(path) {
				row.Blocked = "系统保护项目或路径包含链接，已保留"
				p.Items = append(p.Items, row)
				continue
			}
			check, cancel := context.WithTimeout(ctx, 8*time.Second)
			e = mole(check, root, "check", path)
			cancel()
			if e != nil {
				row.Blocked = e.Error()
				p.Items = append(p.Items, row)
				continue
			}
			check, cancel = context.WithTimeout(ctx, 5*time.Second)
			row.Bytes, row.Files, row.Fingerprint, e = inventory(check, path)
			cancel()
			if e != nil {
				row.Blocked = "无法完整检查，已保留：" + e.Error()
				row.Bytes = 0
			}
			row.Parent, e = parentIdentity(path)
			if e != nil {
				row.Blocked = "上级目录不可读，已保留"
			}
			p.Items = append(p.Items, row)
		}
	}
	sort.SliceStable(p.Items, func(i, j int) bool {
		if (p.Items[i].Blocked == "") != (p.Items[j].Blocked == "") {
			return p.Items[i].Blocked == ""
		}
		return p.Items[i].Bytes > p.Items[j].Bytes
	})
	dir := stateDir(home)
	if e := os.MkdirAll(dir, 0700); e != nil {
		return p, e
	}
	if !canonical(dir) {
		return p, errors.New("清单目录包含链接")
	}
	data, _ := json.Marshal(p)
	f, e := os.OpenFile(filepath.Join(dir, p.ID+".json"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if e != nil {
		return p, e
	}
	_, e = f.Write(data)
	f.Close()
	return p, e
}
func selected(p plan, s selection) ([]item, error) {
	if p.ID != s.Plan || len(s.Plan) != 32 || time.Since(p.Created) > 30*time.Minute || time.Since(p.Created) < 0 {
		return nil, errors.New("清单已过期，请重新扫描")
	}
	if len(s.IDs) == 0 || len(s.IDs) > 1000 {
		return nil, errors.New("请选择需要清理的项目")
	}
	rows := []item{}
	seen := map[string]bool{}
	for _, id := range s.IDs {
		if seen[id] {
			return nil, errors.New("重复项目")
		}
		seen[id] = true
		found := false
		for _, row := range p.Items {
			if row.ID == id {
				if row.Blocked != "" || row.Fingerprint == "" {
					return nil, errors.New("不能清理受保护项目")
				}
				rows = append(rows, row)
				found = true
				break
			}
		}
		if !found {
			return nil, errors.New("所选项目不在当前清单")
		}
	}
	return rows, nil
}
func clean(ctx context.Context, home, root string, s selection) ([]result, error) {
	if len(s.Plan) != 32 {
		return nil, errors.New("无效清单")
	}
	if _, e := hex.DecodeString(s.Plan); e != nil {
		return nil, errors.New("无效清单")
	}
	dir := stateDir(home)
	if !canonical(dir) {
		return nil, errors.New("清单目录无效")
	}
	data, e := os.ReadFile(filepath.Join(dir, s.Plan+".json"))
	if e != nil {
		return nil, errors.New("请重新扫描")
	}
	var p plan
	if json.Unmarshal(data, &p) != nil {
		return nil, errors.New("清单损坏")
	}
	rows, e := selected(p, s)
	if e != nil {
		return nil, e
	}
	lock, e := os.OpenFile(filepath.Join(dir, s.Plan+".used"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return nil, errors.New("此清单已使用，请重新扫描")
	}
	lock.Close()
	results := []result{}
	for _, row := range rows {
		r := result{ID: row.ID, Name: row.Name}
		if !allowed(home, row.Path) || !canonical(row.Path) {
			r.Error = "路径已变化，已保留"
		} else {
			parent, e := parentIdentity(row.Path)
			if e != nil || parent != row.Parent {
				r.Error = "上级目录已变化，已保留"
			} else {
				check, cancel := context.WithTimeout(ctx, 10*time.Second)
				_, _, hash, e := inventory(check, row.Path)
				cancel()
				if e != nil || hash != row.Fingerprint {
					r.Error = "扫描后内容已变化，请关闭相关应用再扫描"
				} else {
					check, cancel = context.WithTimeout(ctx, 20*time.Second)
					e = mole(check, root, "trash", row.Path)
					cancel()
					if e != nil {
						r.Error = e.Error()
					} else {
						r.Trashed = true
					}
				}
			}
		}
		results = append(results, r)
	}
	return results, nil
}
func main() {
	if os.Geteuid() == 0 {
		fmt.Fprintln(os.Stderr, "请使用客机普通用户")
		os.Exit(1)
	}
	home, e := os.UserHomeDir()
	if e != nil {
		panic(e)
	}
	home, _ = filepath.EvalSymlinks(home)
	exe, _ := os.Executable()
	root := filepath.Dir(exe)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
	defer cancel()
	var output any
	if len(os.Args) != 2 {
		e = errors.New("无效操作")
	} else if os.Args[1] == "scan" {
		output, e = scan(ctx, home, root)
	} else if os.Args[1] == "clean" {
		var s selection
		decoder := json.NewDecoder(io.LimitReader(os.Stdin, 65536))
		decoder.DisallowUnknownFields()
		e = decoder.Decode(&s)
		if e == nil {
			output, e = clean(ctx, home, root, s)
		}
	} else {
		e = errors.New("无效操作")
	}
	if e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
	// Fingerprints and parent identities remain private inside the guest plan.
	if p, ok := output.(plan); ok {
		for i := range p.Items {
			p.Items[i].Fingerprint = ""
			p.Items[i].Parent = ""
		}
		output = p
	}
	json.NewEncoder(os.Stdout).Encode(output)
}
