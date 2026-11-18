//go:build cage_macos_only

package tailnetassets

import "io/fs"

func Linux(string) (fs.File, error) { return nil, fs.ErrNotExist }
