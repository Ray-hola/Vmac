package version

import "testing"

func TestPlacesNameWhereASettingLives(t *testing.T) {
	if got := accountPlace(true); got != "「账户与安全」" {
		t.Fatalf("VMac account place = %q", got)
	}
	if got := proxyPlace(true); got != "「代理线路」" {
		t.Fatalf("VMac proxy place = %q", got)
	}
	// The shared workbench keeps the wording its messages always had.
	if got := accountPlace(false); got != "「设置 → 账户」" {
		t.Fatalf("workbench account place = %q", got)
	}
	if got := proxyPlace(false); got != "网络与代理设置" {
		t.Fatalf("workbench proxy place = %q", got)
	}
	if AccountPlace() != accountPlace(MacOSGuestOnly) || ProxyPlace() != proxyPlace(MacOSGuestOnly) {
		t.Fatal("the exported names do not follow the build")
	}
}
