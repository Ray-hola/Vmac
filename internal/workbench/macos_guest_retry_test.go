package workbench

import (
	"context"
	"errors"
	"os/exec"
	"testing"
	"time"
)

// ssh exits 255 when the connection itself fails, whatever the remote command.
func sshFailure(t *testing.T) error {
	t.Helper()
	err := exec.Command("sh", "-c", "exit 255").Run()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 255 {
		t.Fatalf("expected an exit status 255 error, got %v", err)
	}
	return err
}

func TestRetryGuestSSHKeepsTryingWhileSSHSettles(t *testing.T) {
	failure, calls := sshFailure(t), 0
	out, err := retryGuestSSH(context.Background(), []time.Duration{0, 0, 0}, func(context.Context) ([]byte, error) {
		calls++
		if calls < 3 {
			return nil, failure
		}
		return []byte("receipt"), nil
	})
	if err != nil || string(out) != "receipt" || calls != 3 {
		t.Fatalf("out=%q err=%v calls=%d", out, err, calls)
	}
}

func TestRetryGuestSSHRetriesATimeout(t *testing.T) {
	calls := 0
	_, err := retryGuestSSH(context.Background(), []time.Duration{0}, func(context.Context) ([]byte, error) {
		calls++
		if calls == 1 {
			return nil, context.DeadlineExceeded
		}
		return nil, nil
	})
	if err != nil || calls != 2 {
		t.Fatalf("err=%v calls=%d", err, calls)
	}
}

func TestRetryGuestSSHReturnsOtherFailuresAtOnce(t *testing.T) {
	failure, calls := exec.Command("sh", "-c", "exit 1").Run(), 0
	_, err := retryGuestSSH(context.Background(), []time.Duration{0, 0}, func(context.Context) ([]byte, error) {
		calls++
		return nil, failure
	})
	if !errors.Is(err, failure) || calls != 1 {
		t.Fatalf("a failing guest command must not be repeated: err=%v calls=%d", err, calls)
	}
}

func TestRetryGuestSSHGivesUpAfterItsWaits(t *testing.T) {
	failure, calls := sshFailure(t), 0
	_, err := retryGuestSSH(context.Background(), []time.Duration{0, 0}, func(context.Context) ([]byte, error) {
		calls++
		return nil, failure
	})
	if !errors.Is(err, failure) || calls != 3 {
		t.Fatalf("err=%v calls=%d", err, calls)
	}
}

func TestRetryGuestSSHStopsWhenCancelled(t *testing.T) {
	failure, calls := sshFailure(t), 0
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	started := time.Now()
	_, err := retryGuestSSH(ctx, []time.Duration{time.Hour}, func(context.Context) ([]byte, error) {
		calls++
		return nil, failure
	})
	if !errors.Is(err, failure) || calls != 1 || time.Since(started) > 5*time.Second {
		t.Fatalf("err=%v calls=%d after %v", err, calls, time.Since(started))
	}
}
