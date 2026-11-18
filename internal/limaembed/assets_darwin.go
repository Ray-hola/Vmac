//go:build !cage_macos_only

package limaembed

import "embed"

//go:embed all:assets
var assets embed.FS
