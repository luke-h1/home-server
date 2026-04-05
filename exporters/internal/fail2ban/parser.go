package fail2ban

import (
	"fmt"
	"strconv"
	"strings"
)

type JailStatus struct {
	Name            string
	CurrentlyFailed int
	TotalFailed     int
	CurrentlyBanned int
	TotalBanned     int
	BannedIPs       []string
}

func ParseJailList(output string) ([]string, error) {
	for _, line := range strings.Split(output, "\n") {
		if !strings.Contains(line, "Jail list:") {
			continue
		}

		parts := strings.SplitN(line, "Jail list:", 2)
		raw := strings.TrimSpace(parts[1])
		if raw == "" {
			return nil, nil
		}

		items := strings.Split(raw, ",")
		jails := make([]string, 0, len(items))
		for _, item := range items {
			name := strings.TrimSpace(item)
			if name != "" {
				jails = append(jails, name)
			}
		}
		return jails, nil
	}

	return nil, fmt.Errorf("jail list not found")
}

func ParseJailStatus(name, output string) (JailStatus, error) {
	status := JailStatus{Name: name}

	var err error
	status.CurrentlyFailed, err = findIntField(output, "Currently failed:")
	if err != nil {
		return JailStatus{}, err
	}

	status.TotalFailed, err = findIntField(output, "Total failed:")
	if err != nil {
		return JailStatus{}, err
	}

	status.CurrentlyBanned, err = findIntField(output, "Currently banned:")
	if err != nil {
		return JailStatus{}, err
	}

	status.TotalBanned, err = findIntField(output, "Total banned:")
	if err != nil {
		return JailStatus{}, err
	}

	status.BannedIPs, err = findListField(output, "Banned IP list:")
	if err != nil {
		return JailStatus{}, err
	}

	return status, nil
}

func findIntField(output, field string) (int, error) {
	for _, line := range strings.Split(output, "\n") {
		if !strings.Contains(line, field) {
			continue
		}

		parts := strings.SplitN(line, field, 2)
		value := strings.TrimSpace(parts[1])
		n, err := strconv.Atoi(value)
		if err != nil {
			return 0, fmt.Errorf("parse %q: %w", field, err)
		}
		return n, nil
	}

	return 0, fmt.Errorf("field %q not found", field)
}

func findListField(output, field string) ([]string, error) {
	for _, line := range strings.Split(output, "\n") {
		if !strings.Contains(line, field) {
			continue
		}

		parts := strings.SplitN(line, field, 2)
		raw := strings.TrimSpace(parts[1])
		if raw == "" {
			return nil, nil
		}
		return strings.Fields(raw), nil
	}

	return nil, fmt.Errorf("field %q not found", field)
}
