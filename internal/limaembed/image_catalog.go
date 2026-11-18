//go:build !cage_macos_only

package limaembed

import (
	_ "embed"
	"fmt"
	"io/fs"
)

// Cage owns this pin independently of Lima's periodically regenerated templates.
//
//go:embed host-images/ubuntu-22.04.yaml
var ubuntu2204Image []byte

// ReadImageTemplate returns the pinned images bundled with this application.
func ReadImageTemplate(system string) ([]byte, error) {
	switch system {
	case "ubuntu-22.04":
		return ubuntu2204Image, nil
	case "debian-12", "debian-13", "ubuntu-24.04":
		return fs.ReadFile(assets, "assets/templates/_images/"+system+".yaml")
	default:
		return nil, fmt.Errorf("unsupported host image template %q", system)
	}
}
