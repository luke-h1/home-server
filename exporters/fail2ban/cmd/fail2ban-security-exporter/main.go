package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/luke-h1/home-server/exporters/fail2ban/internal/fail2ban"
)

func main() {
	listenAddr := flag.String("web.listen-address", ":9191", "HTTP listen address")
	socketPath := flag.String("collector.f2b.socket", "/var/run/fail2ban/fail2ban.sock", "Fail2Ban socket path")
	timeout := flag.Duration("collector.timeout", 10*time.Second, "Per-scrape timeout for fail2ban-client calls")
	flag.Parse()

	client := fail2ban.Client{
		Socket:  *socketPath,
		Timeout: *timeout,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		snapshot, err := client.Snapshot(r.Context())
		if err != nil {
			writeMetrics(w, nil, err)
			return
		}
		writeMetrics(w, snapshot, nil)
	})

	server := &http.Server{
		Addr:              *listenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("starting fail2ban-security-exporter on %s", *listenAddr)
	log.Fatal(server.ListenAndServe())
}

func writeMetrics(w http.ResponseWriter, snapshot []fail2ban.JailStatus, scrapeErr error) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")

	var b strings.Builder
	writeType(&b, "f2b_up", "gauge")
	writeSample(&b, "f2b_up", nil, boolToFloat(scrapeErr == nil))
	writeType(&b, "f2b_errors", "counter")
	writeSample(&b, "f2b_errors", nil, boolToFloat(scrapeErr != nil))
	writeType(&b, "f2b_jail_count", "gauge")
	writeSample(&b, "f2b_jail_count", nil, float64(len(snapshot)))

	writeType(&b, "f2b_jail_failed_current", "gauge")
	writeType(&b, "f2b_jail_failed_total", "counter")
	writeType(&b, "f2b_jail_banned_current", "gauge")
	writeType(&b, "f2b_jail_banned_total", "counter")
	writeType(&b, "f2b_jail_banned_ips", "gauge")

	for _, jail := range snapshot {
		labels := map[string]string{"jail": jail.Name}
		writeSample(&b, "f2b_jail_failed_current", labels, float64(jail.CurrentlyFailed))
		writeSample(&b, "f2b_jail_failed_total", labels, float64(jail.TotalFailed))
		writeSample(&b, "f2b_jail_banned_current", labels, float64(jail.CurrentlyBanned))
		writeSample(&b, "f2b_jail_banned_total", labels, float64(jail.TotalBanned))
		writeSample(&b, "f2b_jail_banned_ips", labels, float64(len(jail.BannedIPs)))
	}

	if scrapeErr != nil {
		writeComment(&b, fmt.Sprintf("scrape error: %v", scrapeErr))
	}

	_, _ = w.Write([]byte(b.String()))
}

func writeType(b *strings.Builder, name, metricType string) {
	fmt.Fprintf(b, "# TYPE %s %s\n", name, metricType)
}

func writeSample(b *strings.Builder, name string, labels map[string]string, value float64) {
	fmt.Fprintf(b, "%s%s %s\n", name, formatLabels(labels), strconv.FormatFloat(value, 'f', -1, 64))
}

func writeComment(b *strings.Builder, comment string) {
	comment = strings.ReplaceAll(comment, "\n", " ")
	fmt.Fprintf(b, "# %s\n", comment)
}

func formatLabels(labels map[string]string) string {
	if len(labels) == 0 {
		return ""
	}

	keys := make([]string, 0, len(labels))
	for key := range labels {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	parts := make([]string, 0, len(labels))
	for _, key := range keys {
		value := labels[key]
		escaped := strings.NewReplacer(`\`, `\\`, "\n", `\n`, `"`, `\"`).Replace(value)
		parts = append(parts, fmt.Sprintf(`%s="%s"`, key, escaped))
	}
	return "{" + strings.Join(parts, ",") + "}"
}

func boolToFloat(v bool) float64 {
	if v {
		return 1
	}
	return 0
}
