package workbench

import (
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"

	"al.essio.dev/pkg/shellescape"
	"github.com/Ray-hola/Vmac/internal/cage"
	"github.com/Ray-hola/Vmac/internal/guestos"
	"github.com/Ray-hola/Vmac/internal/managedproxy"
	"github.com/Ray-hola/Vmac/internal/paths"
	"github.com/Ray-hola/Vmac/internal/version"
)

//go:embed vmac-check-targets.json
var vmacTargetCatalog []byte

//go:embed vmac-browser-signals.mjs
var vmacBrowserSignals string

type vmacCheckTarget struct {
	ID    string `json:"id"`
	Group string `json:"group"`
	Name  string `json:"name"`
	URL   string `json:"url,omitempty"`
}

var vmacTargets = func() []vmacCheckTarget {
	var targets []vmacCheckTarget
	if err := json.Unmarshal(vmacTargetCatalog, &targets); err != nil {
		panic(err)
	}
	seen := map[string]bool{}
	for _, target := range targets {
		parsed, err := url.Parse(target.URL)
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || seen[target.ID] || target.ID == "" {
			panic("invalid VMac check catalog")
		}
		seen[target.ID] = true
	}
	return targets
}()

type vmacProtectionCheck struct {
	Label  string `json:"label"`
	State  string `json:"state"`
	Detail string `json:"detail"`
}

type vmacProtection struct {
	State      string                `json:"state"`
	Reason     string                `json:"reason"`
	Lease      string                `json:"lease,omitempty"`
	RunID      string                `json:"run_id,omitempty"`
	Epoch      uint64                `json:"epoch,omitempty"`
	ObservedAt time.Time             `json:"observed_at"`
	ReportAt   *time.Time            `json:"report_at,omitempty"`
	Until      *time.Time            `json:"until,omitempty"`
	Checks     []vmacProtectionCheck `json:"checks"`
}

func (v *vmacProtection) add(label, state, detail string) {
	v.Checks = append(v.Checks, vmacProtectionCheck{label, state, detail})
}

func vmacLease(gate cage.GateStatus) string {
	hash := sha256.Sum256([]byte(fmt.Sprintf("%s/%d/%s/%s", gate.RunID, gate.Epoch, gate.Configuration, gate.Report.ID)))
	return hex.EncodeToString(hash[:16])
}

func vmacGateEvidence(gate cage.GateStatus, cfg cage.Config, now time.Time) error {
	if gate.Mode != cage.GateOpen || gate.Fault || !gate.PolicyVerified || gate.Report == nil || gate.Configuration != cfg.Fingerprint() || !now.Before(gate.Until) {
		return errors.New("客机门禁没有有效的放行记录")
	}
	return gate.Report.Authorizes(gate.RunID, cfg.Fingerprint(), now)
}

func (s *Server) vmacObserveProtection(ctx context.Context) vmacProtection {
	now := time.Now()
	v := vmacProtection{State: "unready", Reason: "等待当前客机的隔离与出口证据", ObservedAt: now, Checks: []vmacProtectionCheck{}}
	s.mu.Lock()
	paused := s.networkPaused
	s.mu.Unlock()
	if paused {
		v.State = "paused"
		v.Reason = "已手动断网，可在隔离报告中恢复"
	}
	v.add("手动断网", map[bool]string{true: "blocked", false: "passed"}[paused], map[bool]string{true: "手动断网已生效", false: "未手动断网"}[paused])
	if s.macosGuest == nil {
		v.add("当前 macOS 客机", "unknown", "等待安装 macOS 客机")
		if !paused {
			v.Reason = "安装并启动客机后可检测出网保护"
		}
		return v
	}
	if !s.vmRunning() {
		v.add("当前 macOS 客机", "unknown", "客机已停止")
		if !paused {
			v.Reason = "客机已停止"
		}
		return v
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cfg, err := loadConfig(s.configPath)
	if err != nil {
		v.add("当前配置", "unknown", "无法读取当前配置")
		return v
	}
	client, err := s.gateClient()
	if err != nil {
		v.add("客机出网门禁", "unknown", "无法联系该客机的门禁")
		return v
	}
	gate, err := client.Status(ctx)
	if err != nil {
		v.add("客机出网门禁", "unknown", "无法验证该客机的门禁")
		return v
	}
	if gate.Configuration != cfg.Fingerprint() || !gate.PolicyVerified || gate.RunID == "" {
		v.add("客机出网门禁", "failed", "门禁绑定、配置或出站策略与当前客机不一致")
		if !paused {
			v.Reason = "当前配置尚未通过门禁检查"
		}
		return v
	}
	v.add("客机出网门禁", "passed", "门禁属于当前客机与已应用配置，私网和宿主端口仍受限")
	if gate.Report != nil {
		v.ReportAt = &gate.Report.CreatedAt
	}
	if !gate.Until.IsZero() {
		v.Until = &gate.Until
	}
	switch {
	case paused:
	case gate.Mode == cage.GateChecking:
		v.State = "checking"
		v.Reason = "正在检查隔离与出口，公网探测暂缓"
	case gate.Report != nil && (!now.Before(gate.Report.CreatedAt.Add(cage.SafetyReportLifetime)) ||
		!gate.Until.IsZero() && !now.Before(gate.Until)):
		v.State = "expired"
		v.Reason = "检测记录或门禁有效期已过"
	case gate.Mode != cage.GateOpen && gate.Reason != "":
		v.Reason = gate.Reason
	}
	evidenceErr := vmacGateEvidence(gate, cfg, now)
	evidence := map[string]cage.SafetyCheck{}
	if gate.Report != nil && gate.Report.RunID == gate.RunID && gate.Report.Configuration == cfg.Fingerprint() {
		for _, check := range gate.Report.Checks {
			evidence[check.ID] = check
		}
	}
	for _, item := range [][2]string{{"exit_consistency", "客机公网出口"}, {"fail_closed", "代理失效时拒绝直连"}} {
		check, found := evidence[item[0]]
		if !found {
			v.add(item[1], "unknown", "当前客机尚无该项证据")
			continue
		}
		state := string(check.State)
		if evidenceErr != nil && state == "passed" {
			state = "stale"
		}
		v.add(item[1], state, check.Evidence)
	}
	store, err := managedproxy.Applied(s.profile, cfg.ProxyURL, cfg.ProxyRevision)
	if err != nil || !managedproxy.Running(ctx, s.profile, store) {
		v.add("Mihomo 核心", "failed", "未找到与当前已应用路线一致的运行核心")
		if v.State == "unready" {
			v.Reason = "当前代理核心未就绪"
		}
		return v
	}
	// The private Unix API checks the selected core/route; a separate local
	// connection verifies that its configured proxy socket is listening.
	dialer := net.Dialer{Timeout: 600 * time.Millisecond}
	conn, err := dialer.DialContext(ctx, "tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(store.Port)))
	if err != nil {
		v.add("Mihomo 核心", "failed", "独立检查未发现本机代理监听")
		return v
	}
	_ = conn.Close()
	v.add("Mihomo 核心", "passed", "核心选路与已应用配置一致，本机代理监听可达")
	s.mu.Lock()
	paused = s.networkPaused
	s.mu.Unlock()
	if paused {
		v.State = "paused"
		v.Reason = "已手动断网，可在隔离报告中恢复"
	}
	if !paused && evidenceErr == nil {
		v.State = "protected"
		v.Reason = "当前客机和已应用代理的保护证据有效"
		v.Lease = vmacLease(gate)
		v.RunID, v.Epoch = gate.RunID, gate.Epoch
	}
	return v
}

func (s *Server) vmacProbeAllowed(ctx context.Context, lease string) bool {
	if len(lease) != 32 {
		return false
	}
	s.mu.Lock()
	paused := s.networkPaused
	s.mu.Unlock()
	if paused {
		return false
	}
	cfg, err := loadConfig(s.configPath)
	if err != nil {
		return false
	}
	client, err := s.gateClient()
	if err != nil {
		return false
	}
	short, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	gate, err := client.Status(short)
	if err != nil || vmacGateEvidence(gate, cfg, time.Now()) != nil || vmacLease(gate) != lease {
		return false
	}
	store, err := managedproxy.Applied(s.profile, cfg.ProxyURL, cfg.ProxyRevision)
	return err == nil && managedproxy.Running(short, s.profile, store)
}

func (s *Server) vmacProtectionStatus(w http.ResponseWriter, r *http.Request) {
	if !s.vmacLocal(w, r) {
		return
	}
	jsonReply(w, s.vmacObserveProtection(r.Context()))
}

func (s *Server) vmacLocal(w http.ResponseWriter, r *http.Request) bool {
	_, nativeLocal := paths.VMacRoot(s.profile)
	if (s.macosGuest == nil && !(version.MacOSGuestOnly && nativeLocal)) || !s.hasTrustedView(r) {
		http.NotFound(w, r)
		return false
	}
	w.Header().Set("Cache-Control", "no-store")
	return true
}

func (s *Server) vmacProxyCheck(w http.ResponseWriter, r *http.Request) {
	if !s.vmacLocal(w, r) {
		return
	}
	state := s.vmacObserveProtection(r.Context())
	if state.Lease == "" {
		jsonReply(w, map[string]any{"protection": state})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	tcp := s.vmacHTTPS(ctx, "https://www.gstatic.com/generate_204", false)
	var udp bool
	if s.vmacProbeAllowed(ctx, state.Lease) {
		answer, _ := s.guestControl(ctx, "exec /usr/bin/dig +short +notcp +ignore +time=3 +tries=1 @1.1.1.1 example.com. A", "vmac-proxy-udp")
		for _, value := range strings.Fields(string(answer)) {
			if ip, err := netip.ParseAddr(value); err == nil && ip.Is4() {
				udp = true
				break
			}
		}
	}
	current := s.vmacObserveProtection(r.Context())
	if current.Lease != state.Lease {
		jsonReply(w, map[string]any{"protection": current, "stale": true})
		return
	}
	jsonReply(w, map[string]any{"protection": current, "tcp": tcp.Status == 204, "udp": udp, "observed_at": time.Now()})
}

func (s *Server) vmacTargetList(w http.ResponseWriter, r *http.Request) {
	if !s.vmacLocal(w, r) {
		return
	}
	targets := append([]vmacCheckTarget(nil), vmacTargets...)
	for i := range targets {
		targets[i].URL = ""
	}
	jsonReply(w, targets)
}

func vmacProbeURL(key string) (address string, body bool) {
	for _, target := range vmacTargets {
		if target.ID == key {
			return target.URL, false
		}
	}
	switch key {
	case "claude-com":
		return "https://claude.com/cdn-cgi/trace", true
	case "claude-ai":
		return "https://claude.ai/cdn-cgi/trace", true
	}
	nonce := randomToken()[:16]
	switch key {
	case "dns-surfshark":
		address = "ipv4.surfsharkdns.com/"
	case "dns-fastly":
		address = "u.fastly-analytics.com/debug_resolver"
	case "dns-v4":
		address = "dns4.browserleaks.net/"
	case "dns-v6":
		address = "dns6.browserleaks.net/"
	default:
		return "", false
	}
	return "https://" + nonce + "." + address, true
}

type vmacHTTPResult struct {
	Status   int               `json:"status,omitempty"`
	MS       int               `json:"ms"`
	OK       bool              `json:"ok"`
	Error    string            `json:"error,omitempty"`
	IP       string            `json:"ip,omitempty"`
	Location string            `json:"loc,omitempty"`
	Edge     string            `json:"colo,omitempty"`
	DNS      []vmacDNSResolver `json:"dns,omitempty"`
	text     string
}

func (s *Server) vmacHTTPS(ctx context.Context, address string, body bool) vmacHTTPResult {
	file := "/dev/null"
	if body {
		file = "-"
	}
	args := []string{"/usr/bin/curl", "--disable", "--proto", "=https", "--noproxy", "*", "--silent", "--show-error", "--connect-timeout", "4", "--max-time", "7"}
	if body {
		args = append(args, "--max-filesize", "49152")
	} else if address != "https://www.gstatic.com/generate_204" {
		args = append(args, "--head")
	}
	args = append(args, "--output", file, "--write-out", "\n%{http_code} %{time_total}", "--", address)
	out, err := s.guestControl(ctx, "exec "+shellescape.QuoteCommand(args), "")
	if err != nil {
		return vmacHTTPResult{Error: "HTTPS 请求失败或超时"}
	}
	text, metadata, _ := strings.Cut(string(out), "\n")
	if body {
		last := strings.LastIndexByte(string(out), '\n')
		if last < 0 {
			return vmacHTTPResult{Error: "HTTPS 返回格式无效"}
		}
		text, metadata = string(out[:last]), string(out[last+1:])
	}
	fields := strings.Fields(metadata)
	if len(fields) != 2 {
		return vmacHTTPResult{Error: "HTTPS 返回格式无效"}
	}
	code, err := strconv.Atoi(fields[0])
	seconds, secErr := strconv.ParseFloat(fields[1], 64)
	if err != nil || secErr != nil || code < 100 || code > 599 || seconds < 0 || seconds > 90 {
		return vmacHTTPResult{Error: "没有收到有效 HTTPS 响应"}
	}
	return vmacHTTPResult{Status: code, MS: int(seconds*1000 + 0.5), OK: true, text: text}
}

func parseVMacTrace(r *vmacHTTPResult) {
	r.OK = r.Status == 200
	if !r.OK {
		if r.Error == "" {
			r.Error = fmt.Sprintf("HTTP %d", r.Status)
		}
		return
	}
	for line := range strings.SplitSeq(r.text, "\n") {
		key, value, _ := strings.Cut(line, "=")
		value = strings.TrimSpace(value)
		switch key {
		case "ip":
			if ip, err := netip.ParseAddr(value); err == nil {
				r.IP = ip.String()
			}
		case "loc":
			if len(value) == 2 {
				r.Location = value
			}
		case "colo":
			if len(value) <= 12 {
				r.Edge = value
			}
		}
	}
	if r.IP == "" {
		r.OK = false
		r.Error = "响应没有有效的出口 IP"
	}
}

type vmacDNSResolver struct {
	IP     string `json:"ip"`
	CC     string `json:"cc,omitempty"`
	Geo    string `json:"geo,omitempty"`
	Org    string `json:"org,omitempty"`
	Source string `json:"source"`
}

func parseVMacDNS(key string, r *vmacHTTPResult) {
	// The provider schemas follow Clash for Claude's ChecksWeb parser.
	var value map[string]json.RawMessage
	r.OK = r.Status == 200 && json.Unmarshal([]byte(r.text), &value) == nil && value != nil
	if !r.OK {
		if r.Error == "" {
			r.Error = "未取得可解析的 DNS 样本"
		}
		return
	}
	add := func(row vmacDNSResolver) {
		ip, err := netip.ParseAddr(row.IP)
		if err == nil && len(r.DNS) < 40 {
			row.IP = ip.String()
			r.DNS = append(r.DNS, row)
		}
	}
	if key == "dns-fastly" {
		var item struct {
			IP, CC string
			Org    string `json:"as_name"`
		}
		if json.Unmarshal(value["dns_resolver_info"], &item) == nil {
			add(vmacDNSResolver{item.IP, item.CC, item.CC, item.Org, "Fastly"})
		}
	} else {
		for ip, raw := range value {
			if key == "dns-surfshark" {
				var item struct{ CountryCode, Country, City, ISP string }
				if json.Unmarshal(raw, &item) == nil {
					add(vmacDNSResolver{ip, item.CountryCode, strings.TrimSpace(item.Country + " " + item.City), item.ISP, "Surfshark"})
				}
			} else {
				var item []string
				if json.Unmarshal(raw, &item) == nil && len(item) >= 3 {
					add(vmacDNSResolver{ip, item[0], item[1], item[2], "BrowserLeaks"})
				}
			}
		}
	}
	r.OK = len(r.DNS) > 0
	if !r.OK {
		r.Error = "本次响应没有有效解析器地址"
	}
}

var vmacProbeSlots = make(chan struct{}, 8)

func (s *Server) vmacProbe(w http.ResponseWriter, r *http.Request) {
	if !s.vmacLocal(w, r) {
		return
	}
	var input struct {
		Key   string `json:"key"`
		Lease string `json:"lease"`
	}
	if !readJSON(w, r, &input, 2048) {
		return
	}
	address, body := vmacProbeURL(input.Key)
	browser := input.Key == "browser-signals"
	if address == "" && !browser {
		http.Error(w, "不允许的检测目标", http.StatusBadRequest)
		return
	}
	select {
	case vmacProbeSlots <- struct{}{}:
		defer func() { <-vmacProbeSlots }()
	case <-r.Context().Done():
		return
	}
	ctx, done := context.WithTimeout(r.Context(), 20*time.Second)
	defer done()
	if !s.vmacProbeAllowed(ctx, input.Lease) {
		http.Error(w, "当前客机、出口或门禁已变化，检测已暂停", http.StatusConflict)
		return
	}
	var result any
	if browser {
		command := shellescape.QuoteCommand([]string{guestos.MacOSBrowserTools + "/editor/lib/node", "--input-type=module", "-e", vmacBrowserSignals, guestos.MacOSBrowserTools})
		data, err := s.guestControl(ctx, "exec "+command, "")
		if err != nil || !json.Valid(data) {
			result = map[string]any{"error": "无法读取当前客机 Chrome 的浏览器环境"}
		}
		if result == nil {
			result = json.RawMessage(data)
		}
	} else {
		report := s.vmacHTTPS(ctx, address, body)
		if strings.HasPrefix(input.Key, "claude-") {
			parseVMacTrace(&report)
		}
		if strings.HasPrefix(input.Key, "dns-") {
			parseVMacDNS(input.Key, &report)
		}
		result = report
	}
	if !s.vmacProbeAllowed(ctx, input.Lease) {
		http.Error(w, "当前客机、出口或门禁已变化，检测已暂停", http.StatusConflict)
		return
	}
	jsonReply(w, result)
}
