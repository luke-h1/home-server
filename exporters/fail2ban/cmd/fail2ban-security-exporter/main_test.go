package main

import (
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/luke-h1/home-server/exporters/fail2ban/internal/fail2ban"
)

func TestWriteMetricsEmitsSingleTypeLinePerMetric(t *testing.T) {
	rec := httptest.NewRecorder()
	writeMetrics(rec, []fail2ban.JailStatus{
		{
			Name:            "sshd",
			CurrentlyFailed: 2,
			TotalFailed:     10,
			CurrentlyBanned: 1,
			TotalBanned:     5,
			BannedIPs:       []string{"203.0.113.10"},
		},
		{
			Name:            "recidive",
			CurrentlyFailed: 0,
			TotalFailed:     1,
			CurrentlyBanned: 0,
			TotalBanned:     3,
		},
	}, nil)

	body := rec.Body.String()

	if strings.Count(body, "# TYPE f2b_jail_banned_current gauge") != 1 {
		t.Fatalf("expected one TYPE line for f2b_jail_banned_current, got output:\n%s", body)
	}
	if !strings.Contains(body, `f2b_jail_banned_total{jail="sshd"} 5`) {
		t.Fatalf("missing sshd banned total metric:\n%s", body)
	}
	if !strings.Contains(body, `f2b_jail_banned_total{jail="recidive"} 3`) {
		t.Fatalf("missing recidive banned total metric:\n%s", body)
	}
}
