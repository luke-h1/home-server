package fail2ban

import (
	"reflect"
	"testing"
)

func TestParseJailList(t *testing.T) {
	output := `Status
|- Number of jail:      3
` + "`" + `- Jail list:   sshd, traefik-auth, recidive
`

	got, err := ParseJailList(output)
	if err != nil {
		t.Fatalf("ParseJailList() error = %v", err)
	}

	want := []string{"sshd", "traefik-auth", "recidive"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ParseJailList() = %v, want %v", got, want)
	}
}

func TestParseJailStatus(t *testing.T) {
	output := `Status for the jail: sshd
|- Filter
|  |- Currently failed: 4
|  |- Total failed: 19
|  ` + "`" + `- Journal matches:  _SYSTEMD_UNIT=ssh.service + _COMM=sshd
` + "`" + `- Actions
   |- Currently banned: 2
   |- Total banned: 11
   ` + "`" + `- Banned IP list: 203.0.113.10 198.51.100.2
`

	got, err := ParseJailStatus("sshd", output)
	if err != nil {
		t.Fatalf("ParseJailStatus() error = %v", err)
	}

	want := JailStatus{
		Name:            "sshd",
		CurrentlyFailed: 4,
		TotalFailed:     19,
		CurrentlyBanned: 2,
		TotalBanned:     11,
		BannedIPs:       []string{"203.0.113.10", "198.51.100.2"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ParseJailStatus() = %#v, want %#v", got, want)
	}
}

func TestParseJailStatusEmptyBanList(t *testing.T) {
	output := `Status for the jail: recidive
|- Filter
|  |- Currently failed: 0
|  |- Total failed: 0
|  ` + "`" + `- File list: /var/log/fail2ban.log
` + "`" + `- Actions
   |- Currently banned: 0
   |- Total banned: 5
   ` + "`" + `- Banned IP list:
`

	got, err := ParseJailStatus("recidive", output)
	if err != nil {
		t.Fatalf("ParseJailStatus() error = %v", err)
	}

	if len(got.BannedIPs) != 0 {
		t.Fatalf("ParseJailStatus() banned IPs = %v, want empty", got.BannedIPs)
	}
	if got.CurrentlyBanned != 0 || got.TotalBanned != 5 {
		t.Fatalf("ParseJailStatus() counts = %#v, want current=0 total=5", got)
	}
}
