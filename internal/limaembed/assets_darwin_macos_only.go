//go:build darwin && cage_macos_only

package limaembed

import "embed"

//go:embed assets/Darwin/*.gz assets/templates/macos-*.yaml assets/templates/_images/macos-*.yaml assets/templates/_default/mounts.yaml
var assets embed.FS
