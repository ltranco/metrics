// Command shim accepts nested JSON health payloads and forwards them to
// VictoriaMetrics as Influx line protocol, preserving the original timestamps.
package main

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	_ "time/tzdata" // scratch image has no tz database
)

var (
	token   = os.Getenv("INGEST_TOKEN")
	vmURL   = envOr("VM_URL", "http://victoriametrics:8428/write")
	loc     *time.Location
	nonWord = regexp.MustCompile(`[^a-zA-Z0-9_]`)
)

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

// flexFloat accepts either a JSON number (146.9) or a quoted one ("146.9").
// iOS Shortcuts emits the quoted form. Unparseable or null values leave ok
// false so the caller skips just that sample instead of failing the batch.
type flexFloat struct {
	val float64
	ok  bool
}

func (f *flexFloat) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return nil
	}
	f.val, f.ok = v, true
	return nil
}

// toNanos accepts epoch seconds, epoch millis, "2026-07-25", or RFC3339.
// Bare dates are interpreted in LOCAL_TZ so daily samples land on the right
// day in a local-time dashboard rather than the previous one.
func toNanos(key string) (int64, error) {
	key = strings.TrimSpace(key)
	if n, err := strconv.ParseFloat(key, 64); err == nil {
		if n > 1e11 {
			n /= 1000
		}
		return int64(n * 1e9), nil
	}
	for _, l := range []string{time.RFC3339, "2006-01-02T15:04:05", "2006-01-02"} {
		if t, err := time.ParseInLocation(l, key, loc); err == nil {
			return t.UnixNano(), nil
		}
	}
	return 0, fmt.Errorf("bad time %q", key)
}

func ingest(w http.ResponseWriter, r *http.Request) {
	got := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	var payload map[string]map[string]flexFloat
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}

	var buf bytes.Buffer
	n := 0
	for metric, samples := range payload {
		field := nonWord.ReplaceAllString(metric, "_")
		for when, val := range samples {
			if !val.ok {
				continue
			}
			ts, err := toNanos(when)
			if err != nil {
				continue // skip junk rather than reject the whole batch
			}
			fmt.Fprintf(&buf, "health,src=ios %s=%g %d\n", field, val.val, ts)
			n++
		}
	}
	if n == 0 {
		fmt.Fprint(w, `{"written":0}`)
		return
	}

	// Heartbeat, stamped at wall-clock now rather than at a sample's date. The
	// daily samples all land on local midnight, so their timestamps say nothing
	// about when the phone last posted -- this is what the dashboard's freshness
	// line reads. Not counted in `written`, which stays a count of real samples.
	fmt.Fprintf(&buf, "health,src=ios ingest=1 %d\n", time.Now().UnixNano())

	resp, err := http.Post(vmURL, "text/plain", &buf)
	if err != nil {
		log.Printf("upstream post: %v", err)
		http.Error(w, "upstream error", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= 300 {
		http.Error(w, "upstream "+resp.Status, http.StatusBadGateway)
		return
	}
	fmt.Fprintf(w, `{"written":%d}`, n)
}

func main() {
	if token == "" {
		log.Fatal("INGEST_TOKEN required")
	}
	var err error
	if loc, err = time.LoadLocation(envOr("LOCAL_TZ", "America/Los_Angeles")); err != nil {
		log.Fatal(err)
	}

	http.HandleFunc("/ingest", ingest)
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "ok")
	})

	log.Print("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
