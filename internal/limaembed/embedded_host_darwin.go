//go:build darwin && arm64 && cgo && !no_vz

package limaembed

import (
	"context"

	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"github.com/lima-vm/lima/v2/pkg/limatype/filenames"
	"github.com/Ray-hola/Vmac/internal/cage"
)

const (
	embeddedSocketEnv = "CAGE_EMBEDDED_VM_SOCKET"
	embeddedTokenEnv  = "CAGE_EMBEDDED_VM_TOKEN"
)

var errNoEmbeddedHost = errors.New("no embedded macOS host")

type embeddedLaunch struct {
	Token     string
	Args      []string
	Config    string
	State     string
	LimaHome  string
	Templates string
	JobID     string
}

func forwardEmbeddedHostagent(args []string) error {
	path := os.Getenv(embeddedSocketEnv)
	if path == "" || args[len(args)-1] != "mac" {
		return errNoEmbeddedHost
	}
	c, err := net.DialTimeout("unix", path, 3*time.Second)
	if err != nil {
		return fmt.Errorf("Cage 主窗口的客机运行器未连接: %w", err)
	}
	defer c.Close()
	launch := embeddedLaunch{
		Token: os.Getenv(embeddedTokenEnv), Args: args, Config: os.Getenv(cage.ConfigEnv),
		State: os.Getenv("AGENT_VM_STATE_DIR"), LimaHome: os.Getenv("LIMA_HOME"),
		Templates: os.Getenv("LIMA_TEMPLATES_PATH"), JobID: os.Getenv(cage.JobEnv),
	}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(stop)
	if err = json.NewEncoder(c).Encode(launch); err != nil {
		return err
	}
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-stop:
			_ = json.NewEncoder(c).Encode("stop")
		case <-done:
		}
	}()
	var result string
	if err = json.NewDecoder(c).Decode(&result); err != nil {
		return err
	}
	if result != "" {
		return errors.New(result)
	}
	return nil
}

// StartEmbeddedVMHost is called once by the actual AppKit application before
// its controller starts. Its socket never reaches the guest.
func StartEmbeddedVMHost(config string) (map[string]string, error) {
	if !filepath.IsAbs(config) {
		return nil, errors.New("客机配置路径必须是绝对路径")
	}
	dir, err := os.MkdirTemp("/tmp", "cage-embedded-")
	if err != nil {
		return nil, err
	}
	socket := filepath.Join(dir, "host.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socket, Net: "unix"})
	if err != nil {
		os.Remove(dir)
		return nil, err
	}
	token := hex.EncodeToString(randBytes())
	os.Setenv(cage.ConfigEnv, config)
	env := map[string]string{embeddedSocketEnv: socket, embeddedTokenEnv: token}
	slot := make(chan struct{}, 1)
	go func() {
		for {
			conn, err := listener.AcceptUnix()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				if err := serveEmbeddedHostagent(conn, token, config, slot); err != nil {
					_ = json.NewEncoder(conn).Encode(err.Error())
					return
				}
				_ = json.NewEncoder(conn).Encode("")
			}()
		}
	}()
	return env, nil
}

func randBytes() []byte {
	data := make([]byte, 32)
	// crypto/rand.Read may only fail on a broken OS RNG. Go terminates rather
	// than continuing with predictable authentication material.
	_, _ = rand.Read(data)
	return data
}

func embeddedPeerPID(conn *net.UnixConn) (int, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var pid int
	var peerErr error
	if err = raw.Control(func(fd uintptr) {
		pid, peerErr = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
	}); err != nil {
		return 0, err
	}
	return pid, peerErr
}

func serveEmbeddedHostagent(conn *net.UnixConn, token, config string, slot chan struct{}) error {
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	var launch embeddedLaunch
	decoder := json.NewDecoder(io.LimitReader(conn, 16<<10))
	if decoder.Decode(&launch) != nil || subtle.ConstantTimeCompare([]byte(launch.Token), []byte(token)) != 1 || launch.Config != config {
		return errors.New("客机运行器认证失败")
	}
	dir, err := embeddedInstanceDirectory(launch, config)
	if err != nil {
		return err
	}
	pid, err := embeddedPeerPID(conn)
	if err != nil || pid <= 1 {
		return errors.New("无法验证客机启动进程身份")
	}

	select {
	case slot <- struct{}{}:
		defer func() { <-slot }()
	default:
		return errors.New("Cage 主窗口已经在运行一台客机")
	}
	stdout, err := os.OpenFile(filepath.Join(dir, filenames.HostAgentStdoutLog), os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer stdout.Close()
	stderr, err := os.OpenFile(filepath.Join(dir, filenames.HostAgentStderrLog), os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer stderr.Close()

	for key, value := range map[string]string{
		"AGENT_VM_STATE_DIR": launch.State, "AGENT_VM_LIMA_HOME": launch.LimaHome,
		"LIMA_HOME": launch.LimaHome, "LIMA_TEMPLATES_PATH": launch.Templates,
	} {
		os.Setenv(key, value)
	}

	stop := make(chan os.Signal, 1)
	_ = conn.SetReadDeadline(time.Time{})
	go func() {
		// A normal signal forwards a line. An unexpected supervisor exit
		// closes the socket and requests the same VM shutdown.
		var command string
		_ = decoder.Decode(&command)
		notifyEmbeddedStop(stop)
	}()
	return runHostagent(context.Background(), launch.Args, stdout, &embeddedHostagent{pid: pid, jobID: launch.JobID, stop: stop, stderr: stderr})
}

func embeddedInstanceDirectory(launch embeddedLaunch, config string) (string, error) {
	// Accept only Lima's command for the bound Mac, using its fixed runtime
	// filenames. This is a lifecycle channel, not a generic command runner.
	invalid := errors.New("客机运行器只能启动已绑定的 macOS 实例")
	if len(launch.Args) < 6 || !isHostagent(launch.Args) || launch.Args[len(launch.Args)-1] != "mac" || !filepath.IsAbs(launch.LimaHome) {
		return "", invalid
	}
	want, err := filepath.EvalSymlinks(filepath.Join(filepath.Dir(config), "state"))
	if err != nil {
		return "", err
	}
	state, err := filepath.EvalSymlinks(launch.State)
	if err != nil || state != want {
		return "", invalid
	}
	dir := filepath.Join(launch.LimaHome, "mac")
	real, err := filepath.EvalSymlinks(dir)
	if err != nil || real != filepath.Join(want, "lima", "mac") {
		return "", invalid
	}
	pid := filepath.Join(dir, filenames.HostAgentPID)
	socket := filepath.Join(dir, filenames.HostAgentSock)
	args := launch.Args
	if args[0] == "--debug" {
		args = args[1:]
	}
	args = args[1 : len(args)-1]
	var havePID, haveSocket, haveGUI bool
	for len(args) > 0 {
		flag := args[0]
		args = args[1:]
		if flag == "--run-gui" {
			haveGUI = true
			continue
		}
		if len(args) == 0 {
			return "", invalid
		}
		value := args[0]
		args = args[1:]
		switch flag {
		case "--pidfile":
			havePID = !havePID && value == pid
		case "--socket":
			haveSocket = !haveSocket && value == socket
		case "--guestagent":
			expected := filepath.Join(launch.State, "share", "lima", "Darwin", "lima-guestagent.Darwin-aarch64.gz")
			actual, agentErr := filepath.EvalSymlinks(value)
			agent, wantErr := filepath.EvalSymlinks(expected)
			if agentErr != nil || wantErr != nil || actual != agent {
				return "", invalid
			}
		default:
			return "", invalid
		}
	}
	if !havePID || !haveSocket || !haveGUI || strings.ContainsAny(launch.JobID, "/\\\n\r") {
		return "", invalid
	}
	return dir, nil
}
