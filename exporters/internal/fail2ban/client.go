package fail2ban

import (
	"context"
	"fmt"
	"os/exec"
	"time"
)

type Runner interface {
	Run(ctx context.Context, socket string, args ...string) ([]byte, error)
}

type CommandRunner struct{}

func (CommandRunner) Run(ctx context.Context, socket string, args ...string) ([]byte, error) {
	cmdArgs := append([]string{"-s", socket}, args...)
	cmd := exec.CommandContext(ctx, "fail2ban-client", cmdArgs...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("fail2ban-client %v: %w: %s", args, err, string(out))
	}
	return out, nil
}

type Client struct {
	Socket  string
	Timeout time.Duration
	Runner  Runner
}

func (c Client) Snapshot(ctx context.Context) ([]JailStatus, error) {
	if c.Runner == nil {
		c.Runner = CommandRunner{}
	}

	callCtx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()

	statusOut, err := c.Runner.Run(callCtx, c.Socket, "status")
	if err != nil {
		return nil, err
	}

	jails, err := ParseJailList(string(statusOut))
	if err != nil {
		return nil, err
	}

	results := make([]JailStatus, 0, len(jails))
	for _, jail := range jails {
		jailOut, err := c.Runner.Run(callCtx, c.Socket, "status", jail)
		if err != nil {
			return nil, err
		}

		parsed, err := ParseJailStatus(jail, string(jailOut))
		if err != nil {
			return nil, err
		}
		results = append(results, parsed)
	}

	return results, nil
}
