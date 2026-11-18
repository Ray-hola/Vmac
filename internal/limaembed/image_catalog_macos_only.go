//go:build cage_macos_only

package limaembed

import "fmt"

func ReadImageTemplate(system string) ([]byte, error) {
	return nil, fmt.Errorf("this build does not include guest image template %q", system)
}
