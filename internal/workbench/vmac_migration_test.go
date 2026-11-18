package workbench

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/Ray-hola/Vmac/internal/cage"
	"github.com/Ray-hola/Vmac/internal/managedproxy"
	"github.com/Ray-hola/Vmac/internal/paths"
)

func TestVMacMigratesInPlaceAndPreservesAccountBinding(t *testing.T) {
	home := t.TempDir()
	old := filepath.Join(home, ".claude-cage")
	next := filepath.Join(home, ".vmac")
	guest := filepath.Join(old, "state", "lima", "mac")
	if err := os.MkdirAll(guest, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(old+"-downloads", 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(old, "macos-guest.json"), []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(guest, "disk"), []byte("existing image"), 0600); err != nil {
		t.Fatal(err)
	}
	disk, err := os.Stat(filepath.Join(guest, "disk"))
	if err != nil {
		t.Fatal(err)
	}
	binding := fmtAccountBinding(filepath.Join(old, "account.json"))
	if err := writePrivate(filepath.Join(old, "environment.json"), cage.EnvironmentRecord{Directory: old + "-downloads"}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(guest, "ssh.config"), []byte("IdentityFile "+old+"/state/lima/_config/user\n"), 0600); err != nil {
		t.Fatal(err)
	}

	lock, err := openControllerLock(old, os.O_CREATE|os.O_RDWR)
	if err != nil {
		t.Fatal(err)
	}
	if err := lockController(lock); err != nil {
		t.Fatal(err)
	}
	if err := MigrateVMacHome(home); err == nil {
		t.Fatal("migration accessed active profile")
	}
	if err = lock.Close(); err != nil {
		t.Fatal(err)
	}

	if err := MigrateVMacHome(home); err != nil {
		t.Fatal(err)
	}
	now, err := os.Stat(filepath.Join(next, "state", "lima", "mac", "disk"))
	if err != nil || !os.SameFile(disk, now) {
		t.Fatal("image inode was changed", err)
	}
	if fmtAccountBinding(filepath.Join(next, "account.json")) != binding {
		t.Fatal("saved unlock credential changed binding")
	}
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("old storage still has profile data")
	}
	data, err := os.ReadFile(filepath.Join(next, "state", "lima", "mac", "ssh.config"))
	if err != nil || bytes.Contains(data, []byte(old)) || !bytes.Contains(data, []byte(next+"/state/lima/")) {
		t.Fatal("SSH location not updated", err)
	}
	if stored, err := cage.LoadEnvironmentRecord(next); err != nil || stored.Directory != next+"-downloads" {
		t.Fatal("transfer location not updated", err)
	}
}

func TestVMacSharesSettingsWithoutSharingGuestState(t *testing.T) {
	root := filepath.Join(t.TempDir(), ".vmac")
	slot := filepath.Join(root, "vms", "abcdef01")
	if err := os.MkdirAll(slot, 0700); err != nil {
		t.Fatal(err)
	}
	cfgPath := filepath.Join(root, "config.json")
	cfg := cage.DefaultConfig()
	cfg.Timezone = "Asia/Tokyo"
	if err := writePrivate(cfgPath, cfg); err != nil {
		t.Fatal(err)
	}
	got, err := cage.Load(filepath.Join(slot, "config.json"))
	if err != nil || got.Timezone != cfg.Timezone {
		t.Fatal("VM does not reuse root config", err)
	}
	if managedproxy.Dir(slot) != managedproxy.Dir(root) || managedproxy.Socket(slot) != managedproxy.Socket(root) {
		t.Fatal("VM does not share Mihomo")
	}
	if cage.DefaultEnvironmentDir(slot) == cage.DefaultEnvironmentDir(root) {
		t.Fatal("VM transfer folder is not isolated")
	}
	if paths.ProductProfile(filepath.Join(root, "vms", "foreign")) != filepath.Join(root, "vms", "foreign") {
		t.Fatal("arbitrary nested profile shared product files")
	}
	shared := Preferences{Keyboard: "abc", Workspace: "/Original", Clock12Hour: true}
	if err := writePrivate(filepath.Join(root, "workbench.json"), shared); err != nil {
		t.Fatal(err)
	}
	preferences, err := loadSharedVMacPreferences(slot, Preferences{Workspace: "/Other"})
	if err != nil || preferences.Workspace != "/Other" || !preferences.Clock12Hour {
		t.Fatal("VM did not retain own workspace and reuse app settings", err)
	}
	s := &Server{profile: slot}
	preferences.Clock12Hour = false
	if err := s.savePreferences(preferences); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(root, "workbench.json"))
	if err != nil || !bytes.Contains(data, []byte("/Original")) || bytes.Contains(data, []byte("/Other")) || !bytes.Contains(data, []byte(`"clock_12_hour": false`)) {
		t.Fatal("app preferences update crossed guest workspace boundary", err)
	}
}
