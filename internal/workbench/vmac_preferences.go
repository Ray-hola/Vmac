package workbench

import (
	"encoding/json"
	"os"
	"path/filepath"

	"github.com/Ray-hola/Vmac/internal/paths"
)

// Application preferences follow the account. Workspace selection and phone
// relay configuration stay with the VM that owns those sessions and grants.
func loadSharedVMacPreferences(profile string, fallback Preferences) (Preferences, error) {
	root := paths.ProductProfile(profile)
	if root == profile {
		return fallback, nil
	}
	data, err := os.ReadFile(filepath.Join(root, "workbench.json"))
	if os.IsNotExist(err) {
		return fallback, nil
	}
	if err != nil {
		return fallback, err
	}
	preferences := fallback
	if err := json.Unmarshal(data, &preferences); err != nil {
		return fallback, err
	}
	preferences.Workspace = fallback.Workspace
	preferences.MobileRelay = fallback.MobileRelay
	return preferences, nil
}

func (s *Server) savePreferences(preferences Preferences) error {
	local := filepath.Join(s.profile, "workbench.json")
	root := paths.ProductProfile(s.profile)
	if root == s.profile {
		return writePrivate(local, preferences)
	}
	shared := filepath.Join(root, "workbench.json")
	previous, err := os.ReadFile(shared)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	var original Preferences
	if len(previous) > 0 {
		if err := json.Unmarshal(previous, &original); err != nil {
			return err
		}
	}
	common := preferences
	common.Workspace = original.Workspace
	common.MobileRelay = original.MobileRelay
	if err := writePrivate(shared, common); err != nil {
		return err
	}
	if err := writePrivate(local, preferences); err != nil {
		// Restore shared options if the local VM settings could not be saved.
		if len(previous) > 0 {
			_ = writePrivate(shared, original)
		} else {
			_ = os.Remove(shared)
		}
		return err
	}
	return nil
}
