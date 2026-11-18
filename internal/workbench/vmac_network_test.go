package workbench

import (
	"net/url"
	"strings"
	"testing"
)

func TestVMacProbeTargetsAndDNSNonces(t *testing.T) {
	counts := map[string]int{}
	for _, target := range vmacTargets {
		counts[target.Group]++
	}
	if len(counts) != 4 || counts["cn"] != 12 || counts["jp"] != 8 || counts["us"] != 24 || counts["gl"] != 16 {
		t.Fatalf("catalog drift: %v", counts)
	}
	for _, bad := range []string{"https://example.org", "../site-0", "site-999", "127.0.0.1", ""} {
		if value, _ := vmacProbeURL(bad); value != "" {
			t.Fatalf("arbitrary probe destination accepted: %q", bad)
		}
	}
	for _, key := range []string{"dns-v4", "dns-v6", "dns-fastly", "dns-surfshark"} {
		a, body := vmacProbeURL(key)
		b, _ := vmacProbeURL(key)
		parsed, err := url.Parse(a)
		if err != nil || parsed.Scheme != "https" || a == b || !body || len(strings.Split(parsed.Hostname(), ".")[0]) != 16 {
			t.Fatalf("resolver probe does not use a fresh HTTPS name for %s", key)
		}
	}
}

func TestVMacProbeParsesOnlyTraceAndResolverEvidence(t *testing.T) {
	trace := vmacHTTPResult{Status: 200, text: "forbidden=ignore\nip=203.0.113.5\nloc=JP\ncolo=NRT\n"}
	parseVMacTrace(&trace)
	if !trace.OK || trace.IP != "203.0.113.5" || trace.Edge != "NRT" || trace.Location != "JP" {
		t.Fatalf("trace parsing failed: %+v", trace)
	}
	trace = vmacHTTPResult{Status: 200, text: "ip=arbitrary text\n"}
	parseVMacTrace(&trace)
	if trace.OK {
		t.Fatal("invalid trace IP was accepted")
	}
	samples := []struct{ key, body, source string }{
		{"dns-fastly", `{"dns_resolver_info":{"ip":"203.0.113.8","cc":"JP","as_name":"fixture"}}`, "Fastly"},
		{"dns-surfshark", `{"203.0.113.8":{"CountryCode":"JP","City":"fixture"},"malformed":{"CountryCode":"CN"}}`, "Surfshark"},
		{"dns-v4", `{"203.0.113.8":["JP","fixture","ISP"],"wrong key":[]}`, "BrowserLeaks"},
	}
	for _, sample := range samples {
		out := vmacHTTPResult{Status: 200, text: sample.body}
		parseVMacDNS(sample.key, &out)
		if !out.OK || len(out.DNS) != 1 || out.DNS[0].IP != "203.0.113.8" || out.DNS[0].Source != sample.source {
			t.Fatalf("%s sample parsing failed: %+v", sample.key, out)
		}
	}
}
