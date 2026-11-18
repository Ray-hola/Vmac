// Package limaembed runs what Lima's libraries expect of limactl: they start
// the current executable again for some commands (`hostagent`, from
// instance.Start), and look for the guest agent and the templates next to it.
package limaembed

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/sirupsen/logrus"
	"github.com/spf13/cobra"

	"github.com/docker/go-units"
	"github.com/lima-vm/lima/v2/pkg/debugutil"
	"github.com/lima-vm/lima/v2/pkg/driver"
	"github.com/lima-vm/lima/v2/pkg/driver/external/server"
	"github.com/lima-vm/lima/v2/pkg/envutil"
	"github.com/lima-vm/lima/v2/pkg/hostagent"
	"github.com/lima-vm/lima/v2/pkg/hostagent/dns"
	"github.com/lima-vm/lima/v2/pkg/limatype"
	"github.com/lima-vm/lima/v2/pkg/networks/usernet"
	"github.com/lima-vm/lima/v2/pkg/osutil"
	"github.com/lima-vm/sshocker/pkg/reversesshfs"

	"github.com/Ray-hola/Vmac/internal/cage"
	"github.com/Ray-hola/Vmac/internal/diagnostics"
	"github.com/Ray-hola/Vmac/internal/guard"
	"github.com/Ray-hola/Vmac/internal/guestos"
	"github.com/Ray-hola/Vmac/internal/netguard"
	"github.com/Ray-hola/Vmac/internal/state"
	"github.com/Ray-hola/Vmac/internal/vmname"
)

// Run runs args (os.Args[1:]) when they are a command Lima's libraries start
// this executable for, as limactl would, and reports whether they were. Such
// a command never returns: it exits.
func Run(args []string) bool {
	if !isHostagent(args) {
		return false
	}
	err := forwardEmbeddedHostagent(args)
	if errors.Is(err, errNoEmbeddedHost) {
		err = runHostagent(context.Background(), args, os.Stdout, nil)
	}
	osutil.HandleExitError(err)
	if err != nil {
		logrus.Fatal(err)
	}
	os.Exit(0)
	return true
}

func isHostagent(args []string) bool {
	i := 0
	for i < len(args) && args[i] == "--debug" {
		i++
	}
	return i < len(args) && args[i] == "hostagent"
}

type embeddedHostagent struct {
	pid    int
	jobID  string
	stop   chan os.Signal
	stderr io.Writer
}

func runHostagent(ctx context.Context, args []string, out io.Writer, embedded *embeddedHostagent) error {
	var stopGateControl func()
	var stopJobWatch func()
	var diagnosticStream *diagnostics.Stream
	if path := os.Getenv(cage.ConfigEnv); path != "" {
		hostagent.ManageResources = func(ctx context.Context, dir string, cfg *limatype.LimaYAML, balloon driver.MemoryBalloon, read func(context.Context, string) ([]byte, error)) func() {
			maximum, err := units.RAMInBytes(*cfg.Memory)
			if err != nil || *cfg.OS != limatype.LINUX {
				return func() {}
			}
			return cage.StartResourceManager(ctx, dir, uint64(maximum), *cfg.CPUs, read, balloon.SetMemoryTarget)
		}
		diagnosticStream = diagnostics.New(filepath.Dir(path)).Stream("vm-hostagent", "warn")
		diagnostics.SetDefault(diagnostics.New(filepath.Dir(path)))
		if embedded == nil {
			logrus.SetOutput(diagnosticStream)
		} else {
			logger := logrus.StandardLogger()
			oldOut, oldFormatter, oldLevel := logger.Out, logger.Formatter, logger.Level
			defer func() { logger.SetOutput(oldOut); logger.SetFormatter(oldFormatter); logger.SetLevel(oldLevel) }()
			logrus.SetOutput(embedded.stderr)
		}
		defer diagnosticStream.Close()
	}
	if runtime.GOOS == "windows" {
		windowsPath()
	}
	// Lima's own port forwarder, the one patched to never take a port a
	// program of the host serves; not the ssh one.
	os.Unsetenv("LIMA_SSH_PORT_FORWARDER")
	// What the guest may reach (netguard): every connection it opens is made
	// here, by the instance's netstack. An unreadable policy stops the VM
	// rather than leave it open.
	st, err := state.Default()
	if err != nil {
		return err
	}
	policy, err := netguard.Load(string(st))
	if err != nil {
		return err
	}
	if embedded != nil {
		usernet.ResetHostServices()
		usernet.DroppedIPv6 = nil
		defer usernet.ResetHostServices()
	}
	usernet.Outbound = policy.Allows
	if len(policy.Domains) > 0 {
		// Both resolvers the guest can reach: the gateway's, which every
		// query gets whatever the guest's iptables say, and the hostagent's.
		usernet.Names, usernet.Answered = policy.Name, policy.Answered
		dns.Names, dns.Answered = policy.Name, policy.Answered
	}
	if path := os.Getenv(cage.ConfigEnv); path != "" {
		pid, jobID, notify := os.Getpid(), os.Getenv(cage.JobEnv), notifyHostagentStop
		if embedded != nil {
			pid, jobID = embedded.pid, embedded.jobID
			notify = func() { notifyEmbeddedStop(embedded.stop) }
		}
		stopJobWatch, err = cage.WatchJobStop(filepath.Dir(path), jobID, notify)
		if err != nil {
			return err
		}
		defer stopJobWatch()
		cfg, err := cage.Load(path)
		if err != nil {
			return err
		}
		if err = cfg.RequireManagedProxy(filepath.Dir(path)); err != nil {
			return err
		}
		usernet.Names, usernet.Answered = nil, nil
		dns.Names, dns.Answered = nil, nil
		name := args[len(args)-1]
		if name == vmname.Template+"-building" {
			// The base builder installs trusted tooling before any project is
			// mounted. Project VMs always start with the external gate closed.
			egress, err := cage.NewEgress(cfg)
			if err != nil {
				return err
			}
			usernet.Outbound, usernet.GuestDial = egress.Allows, egress.DialContext
			usernet.DNSExchange, dns.Exchange = egress.ExchangeDNS, egress.ExchangeDNS
		} else {
			gate, err := cage.NewEgressGate(cfg)
			if err != nil {
				return err
			}
			if stopGateControl, err = cage.StartGateControlForProcess(path, filepath.Join(string(st), "lima", name), gate, pid, jobID); err != nil {
				return err
			}
			defer stopGateControl()
			if embedded != nil {
				defer gate.Close("macOS 客机已停止")
			}
			if name == "mac" {
				// The installed Mac profile binds this exact VZ instance. Other
				// workloads retain their existing switch behavior.
				if binding, err := guestos.LoadMacOSProfile(filepath.Dir(path)); err != nil {
					return err
				} else if binding != nil && binding.Instance == name {
					usernet.DroppedIPv6 = gate.ObserveDroppedIPv6
				}
			}
			usernet.Outbound, usernet.GuestDial = gate.Allows, gate.DialContext
			usernet.DNSExchange, dns.Exchange = gate.ExchangeDNS, gate.ExchangeDNS
		}
		if filepath.Base(name) != name {
			return fmt.Errorf("invalid Cage instance %q", name)
		}
		dir := filepath.Join(string(st), "lima", name)
		if err := cfg.RecordRunningProcess(dir, pid, jobID); err != nil {
			return err
		}
		if embedded != nil {
			defer os.Remove(filepath.Join(dir, "cage-running.json"))
		}
	}
	// The user is asked before the VM changes a file their machine runs on
	// its own (guard): the shares' SFTP server runs here.
	if os.Getenv(cage.ConfigEnv) == "" {
		g, err := guard.Load(string(st), args[len(args)-1])
		if err != nil {
			return err
		}
		reversesshfs.Guard = g.Allow
	} else {
		// Cage grants normal file access inside explicitly shared directories.
		reversesshfs.Guard = nil
	}
	root := &cobra.Command{
		Use:           "agent-vm",
		SilenceUsage:  true,
		SilenceErrors: true,
		PersistentPreRun: func(cmd *cobra.Command, _ []string) {
			if debug, _ := cmd.Flags().GetBool("debug"); debug {
				logrus.SetLevel(logrus.DebugLevel)
				debugutil.Debug = true
			}
		},
	}
	root.PersistentFlags().Bool("debug", false, "debug mode")
	root.AddCommand(newHostagentCommand())
	root.SetArgs(args)
	// Its events, as limactl's, and a notice for each port it forwards. The
	// instance is the last argument.
	root.SetOut(newEventWatch(out, args[len(args)-1]))
	if embedded != nil {
		root.SetErr(embedded.stderr)
		ctx = context.WithValue(ctx, embeddedHostagentKey{}, embedded)
	} else if diagnosticStream != nil {
		root.SetErr(diagnosticStream)
	}
	defer server.Disconnect()
	return root.ExecuteContext(ctx)
}

// windowsPath puts QEMU's usual folders on PATH, as limactl's main does.
func windowsPath() {
	if extras, ok := os.LookupEnv("_LIMA_WINDOWS_EXTRA_PATH"); ok && strings.TrimSpace(extras) != "" {
		_ = os.Setenv("PATH", strings.TrimSpace(extras)+string(filepath.ListSeparator)+os.Getenv("PATH"))
	}
	p := os.Getenv("PATH")
	if np := envutil.AppendDirsToPath(p, envutil.PlatformCommonToolDirs); np != p {
		_ = os.Setenv("PATH", np)
	}
}
