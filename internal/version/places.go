package version

// Where a message sends the user for a setting. VMac spread the old settings
// panel over its own pages, so there a message names the page; the shared
// workbench keeps the panel and the wording its messages always had. The
// page titles are those of ui/src/vmac-pages.mjs; a test there keeps them in
// step.

// AccountPlace is where the account's password and unlock methods are set.
func AccountPlace() string { return accountPlace(MacOSGuestOnly) }

// ProxyPlace is where nodes, subscriptions, DNS and the exit rule are set.
func ProxyPlace() string { return proxyPlace(MacOSGuestOnly) }

func accountPlace(vmac bool) string {
	if vmac {
		return "「账户与安全」"
	}
	return "「设置 → 账户」"
}

func proxyPlace(vmac bool) string {
	if vmac {
		return "「代理线路」"
	}
	return "网络与代理设置"
}
