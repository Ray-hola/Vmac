package workbench

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

func (s *Server) macOSInputSources(w http.ResponseWriter, r *http.Request) {
	if !s.nativeMacOSTransferReady(w, r) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	if r.Method == http.MethodPost {
		if _, err := s.guest(ctx, `/usr/bin/open 'x-apple.systempreferences:com.apple.Keyboard-Settings.extension'`); err != nil {
			http.Error(w, "无法打开客机键盘设置，请确认客机已解锁", http.StatusBadGateway)
			return
		}
		jsonReply(w, map[string]bool{"opened": true})
		return
	}
	const command = `/usr/bin/defaults export com.apple.HIToolbox - | /usr/bin/plutil -convert json -o - -`
	raw, err := s.guest(ctx, command)
	var preferences struct {
		Enabled  []map[string]any `json:"AppleEnabledInputSources"`
		Selected []map[string]any `json:"AppleSelectedInputSources"`
		Layout   string           `json:"AppleCurrentKeyboardLayoutInputSourceID"`
	}
	if err != nil || json.Unmarshal(raw, &preferences) != nil {
		http.Error(w, "暂时无法读取客机输入法", http.StatusBadGateway)
		return
	}
	inputSourceName := func(source map[string]any) string {
		for _, key := range []string{"KeyboardLayout Name", "Input Mode", "Bundle ID"} {
			if value, _ := source[key].(string); value != "" {
				return value
			}
		}
		return ""
	}
	names := func(sources []map[string]any) []string {
		list := []string{}
		for _, source := range sources {
			kind, _ := source["InputSourceKind"].(string)
			if kind == "Non Keyboard Input Method" {
				continue
			}
			if name := inputSourceName(source); name != "" {
				list = append(list, name)
			}
		}
		return list
	}
	enabled, selected := names(preferences.Enabled), names(preferences.Selected)
	if len(selected) == 0 {
		if layout, ok := strings.CutPrefix(preferences.Layout, "com.apple.keylayout."); ok && layout != "" {
			selected = []string{layout}
		} else if len(enabled) == 1 {
			selected = enabled
		}
	}
	jsonReply(w, map[string][]string{"enabled": enabled, "selected": selected})
}
