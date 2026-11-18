package paths

import (
	"os"
	"path/filepath"
	"regexp"
)

var vmacGuestID = regexp.MustCompile("^[0-9a-f]{8}$")

// VMacRoot returns the common product directory for the original profile
// and managed VM slots. An arbitrary external profile remains independent.
func VMacRoot(profile string) (string, bool) {
	profile = filepath.Clean(profile)
	if filepath.Base(profile) == ".vmac" {
		return profile, true
	}
	slots := filepath.Dir(profile)
	root := filepath.Dir(slots)
	if filepath.Base(slots) == "vms" && filepath.Base(root) == ".vmac" && vmacGuestID.MatchString(filepath.Base(profile)) {
		return root, true
	}
	return profile, false
}

func ProductProfile(profile string) string {
	if root, ok := VMacRoot(profile); ok {
		return root
	}
	return profile
}

func VMacConfigPath(path string) string {
	root, ok := VMacRoot(filepath.Dir(path))
	if ok && filepath.Base(path) == "config.json" {
		return filepath.Join(root, "config.json")
	}
	return path
}

func VMacHome() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".vmac")
}
