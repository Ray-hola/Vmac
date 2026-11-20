package workbench

import (
	"errors"
	"net/http"
	"net/url"
	"path/filepath"
)

type connectionTransport struct {
	base http.RoundTripper
	id   string
}

func (t connectionTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	copy := r.Clone(r.Context())
	copy.Header.Set(connectionHeader, t.id)
	return t.base.RoundTrip(copy)
}

func (t connectionTransport) CloseIdleConnections() {
	if closer, ok := t.base.(interface{ CloseIdleConnections() }); ok {
		closer.CloseIdleConnections()
	}
}

// A native picker captures the connection before the user selects a file.
// Matching it here prevents a slow picker from sending that file to a newly
// selected server. Native calls from old local builds may omit it only locally.
// A controller without connection contexts serves only its local workload.
func (c *controllerClient) bindConnection(expected string) (ClientContext, error) {
	var current ClientContext
	status, err := c.call("GET", "/api/client/context", nil, &current)
	if err == nil && status == http.StatusNotFound && (expected == "" || expected == "local") {
		return ClientContext{Mode: "local", ConnectionID: "local"}, nil
	}
	if err != nil || status != http.StatusOK {
		return current, errors.New("无法核对当前文件传递连接")
	}
	if current.DesktopGateway && (expected == "" || current.Mode == "none") {
		return current, errors.New("请先选择工作环境，再重新进行文件操作")
	}
	if current.Mode == "remote" && (expected == "" || current.State.State != "connected") {
		return current, errors.New("远程连接不可用，请重新连接后选择文件")
	}
	if expected != "" && expected != current.ConnectionID {
		return current, errors.New("连接已经切换，请在当前主机重新选择文件")
	}
	c.connectionID = current.ConnectionID
	c.client.Transport = connectionTransport{base: c.client.Transport, id: current.ConnectionID}
	return current, nil
}

// openFileSession signs in with the launch ticket as the local view that ran
// this command, then binds the transfer to the expected connection. Guest
// controllers admit only that trusted view, as for agent requests.
func (c *controllerClient) openFileSession(connectionID string) error {
	entry, _ := url.Parse(c.launch.URL)
	status, err := c.call("POST", "/api/session", map[string]string{"token": entry.Fragment}, nil)
	if err != nil || status != http.StatusOK {
		return errors.New("无法连接剪贴板会话")
	}
	c.setTrustedViewCookie(entry)
	_, err = c.bindConnection(connectionID)
	return err
}

func clientDownloadProfile(profile string, current ClientContext) (string, error) {
	if current.Mode != "remote" {
		return profile, nil
	}
	if !remoteInstanceID.MatchString(current.InstanceID) {
		return "", errors.New("远程实例身份无效")
	}
	return filepath.Join(profile, "remote-downloads", current.InstanceID), nil
}
