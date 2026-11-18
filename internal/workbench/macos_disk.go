package workbench

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"time"

	qcow2reader "github.com/lima-vm/go-qcow2reader"
	"github.com/lima-vm/lima/v2/pkg/plist"
	"go.yaml.in/yaml/v3"
)

const gib = int64(1 << 30)

func macDiskSize(path string) (string, int64, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return "", 0, errors.New("未找到本机客机的磁盘镜像")
	}
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	img, err := qcow2reader.Open(f)
	if err != nil {
		return "", 0, err
	}
	defer img.Close()
	return string(img.Type()), img.Size(), nil
}

func (s *Server) macOSDisk(w http.ResponseWriter, r *http.Request) {
	if runtime.GOOS != "darwin" || s.macosGuest == nil || !s.hasTrustedView(r) {
		http.NotFound(w, r)
		return
	}
	dir := s.instanceDir()
	disk := filepath.Join(dir, "disk")
	if r.Method == http.MethodGet {
		format, size, err := macDiskSize(disk)
		if err != nil {
			requestError(w, err)
			return
		}
		jsonReply(w, map[string]any{"bytes": size, "format": format, "expandable": format == "asif"})
		return
	}
	var input struct {
		GiB int64 `json:"gib"`
	}
	if !readJSON(w, r, &input) {
		return
	}
	if input.GiB < 1 || input.GiB > 2048 {
		requestError(w, errors.New("请输入 1–2048 GiB 的目标容量"))
		return
	}
	s.launch(w, "disk-grow", func() error {
		format, current, err := macDiskSize(disk)
		if err != nil {
			return err
		}
		target := input.GiB * gib
		if format != "asif" || target <= current {
			return errors.New("此操作仅支持扩大 ASIF 磁盘镜像")
		}
		if s.vmRunning() {
			s.setMessage("正在关闭网络并停止客机…")
			_ = s.closeProxyGate("客机磁盘即将扩容")
			if err := s.stopEnvironment(); err != nil {
				return err
			}
		}
		if s.vmRunning() {
			return errors.New("客机仍在运行，未修改磁盘")
		}
		return s.expandMacDisk(dir, disk, current, target)
	})
}

func macDiskAPFSCapacity(ctx context.Context, disk string) (int64, error) {
	output, err := exec.CommandContext(ctx, "/usr/sbin/diskutil", "image", "info", "--plist", disk).Output()
	if err != nil {
		return 0, err
	}
	var details plist.Plist
	if err = xml.Unmarshal(output, &details); err != nil {
		return 0, err
	}
	var largest int64
	for _, partition := range details.Value.Dict["Partitions"].Array {
		hint := partition.Dict["content-hint"].String
		size := partition.Dict["total-space"].Integer
		if hint != nil && *hint == "Apple_APFS" && size != nil && *size > largest {
			largest = *size
		}
	}
	if largest == 0 {
		return 0, errors.New("无法识别客机 APFS 主分区")
	}
	return largest, nil
}

// Expand a copy first. The original image remains available even if diskutil
// rejects the partition layout, the volume lacks space, or the job is canceled.
func (s *Server) expandMacDisk(dir, disk string, current, target int64) error {
	ctx := s.operationContext()
	oldAPFS, err := macDiskAPFSCapacity(ctx, disk)
	if err != nil {
		return fmt.Errorf("无法检查客机 APFS 分区，原磁盘已保留：%w", err)
	}
	configPath := filepath.Join(dir, "lima.yaml")
	originalConfig, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	var document yaml.Node
	if err = yaml.Unmarshal(originalConfig, &document); err != nil {
		return err
	}
	if len(document.Content) != 1 || document.Content[0].Kind != yaml.MappingNode {
		return errors.New("客机配置格式无效")
	}
	fields := document.Content[0].Content
	updated := false
	for i := 0; i < len(fields); i += 2 {
		if fields[i].Value == "disk" {
			fields[i+1].SetString(strconv.FormatInt(target/gib, 10) + "GiB")
			updated = true
		}
	}
	if !updated {
		return errors.New("客机配置没有磁盘容量字段")
	}
	config, err := yaml.Marshal(&document)
	if err != nil {
		return err
	}
	stage, err := os.MkdirTemp(dir, ".disk-grow-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	copyPath := filepath.Join(stage, "disk")
	s.setMessage("正在生成磁盘副本并检查容量…")
	if err = exec.CommandContext(ctx, "/bin/cp", "-c", disk, copyPath).Run(); err != nil {
		return errors.New("无法创建磁盘副本，请检查宿主机可用空间")
	}
	s.setMessage("正在扩大客机磁盘和文件系统…")
	output, err := exec.CommandContext(ctx, "/usr/sbin/diskutil", "image", "resize", "--size", strconv.FormatInt(target, 10), copyPath).CombinedOutput()
	if err != nil {
		line := bytes.TrimSpace(output)
		if len(line) > 420 {
			line = line[:420]
		}
		return fmt.Errorf("系统扩容工具无法扩大此镜像，原磁盘已保留：%s", line)
	}
	format, size, err := macDiskSize(copyPath)
	if err != nil || format != "asif" || size != target {
		return errors.New("系统未返回预期的磁盘容量，原磁盘已保留")
	}
	newAPFS, err := macDiskAPFSCapacity(ctx, copyPath)
	if err != nil || newAPFS <= oldAPFS || newAPFS-oldAPFS < target-current-(8<<20) {
		return errors.New("镜像容量已扩大，但 macOS 主分区未获得预期空间，原磁盘已保留")
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	backup, err := os.MkdirTemp(dir, "disk-before-"+time.Now().Format("20060102")+"-")
	if err != nil {
		return err
	}
	backupDisk := filepath.Join(backup, "disk")
	if err = os.Link(disk, backupDisk); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(backup, "lima.yaml"), originalConfig, 0600); err != nil {
		return err
	}
	newConfig := filepath.Join(stage, "lima.yaml")
	if err = os.WriteFile(newConfig, config, 0600); err != nil {
		return err
	}
	// Publish the larger image last. A process interruption before publication
	// leaves the original image and matching configuration in the backup.
	if err = os.Rename(newConfig, configPath); err != nil {
		return err
	}
	if err = os.Rename(copyPath, disk); err != nil {
		return errors.Join(err, os.Rename(filepath.Join(backup, "lima.yaml"), configPath))
	}
	return nil
}
