//go:build darwin && cage_macos_only

package limaembed

import (
	"io/fs"
	"strings"
	"testing"
)

func TestMacOSOnlyAssets(t *testing.T) {
	share, err := WriteShare(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := share.GuestAgent("Darwin", guestArch()); err != nil {
		t.Fatal(err)
	}
	if _, err := share.GuestAgent("Linux", guestArch()); err == nil {
		t.Fatal("Linux guest agent was packaged")
	}
	if err := fs.WalkDir(assets, "assets/templates", func(path string, entry fs.DirEntry, err error) error {
		if err == nil && !entry.IsDir() && !strings.HasPrefix(entry.Name(), "macos-") && path != "assets/templates/_default/mounts.yaml" {
			t.Errorf("non-macOS template was packaged: %s", path)
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
}
