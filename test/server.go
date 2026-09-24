package main

import (
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/body", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		io.WriteString(w, "hello\x00\xffworld")
	})
	mux.HandleFunc("/echo", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Method", r.Method)
		for _, value := range r.Header.Values("X-Test") {
			w.Header().Add("X-Seen", value)
		}
		w.Header().Add("Set-Cookie", "first=1")
		w.Header().Add("Set-Cookie", "second=2")
		io.Copy(w, r.Body)
	})
	mux.HandleFunc("/status/{code}", func(w http.ResponseWriter, r *http.Request) {
		code, _ := strconv.Atoi(r.PathValue("code"))
		w.WriteHeader(code)
		io.WriteString(w, "status body")
	})
	mux.HandleFunc("/redirect/{code}", func(w http.ResponseWriter, r *http.Request) {
		code, _ := strconv.Atoi(r.PathValue("code"))
		w.Header().Set("Location", r.URL.Query().Get("to"))
		w.Header().Set("X-Redirect-Only", "discard me")
		w.WriteHeader(code)
		io.WriteString(w, strings.Repeat("redirect body", 100))
	})
	mux.HandleFunc("/loop", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", "/loop")
		w.WriteHeader(http.StatusFound)
	})
	mux.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "partial")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	})
	mux.HandleFunc("/truncated", func(w http.ResponseWriter, r *http.Request) {
		conn, buffer, err := w.(http.Hijacker).Hijack()
		if err != nil {
			panic(err)
		}
		defer conn.Close()
		buffer.WriteString("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort")
		buffer.Flush()
	})
	mux.HandleFunc("/archive", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, os.Args[2])
	})
	mux.HandleFunc("/plugin/values", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `dotcmd_plugin_test_calls = (dotcmd_plugin_test_calls or 0) + 1
return "value", nil, false, dotcmd_plugin_test_calls, type(cached) .. ":" .. host.os`)
	})
	mux.HandleFunc("/plugin/syntax", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `return function(`)
	})
	mux.HandleFunc("/plugin/runtime", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `error("plugin runtime failure")`)
	})
	mux.HandleFunc("/launcher/{version}", func(w http.ResponseWriter, r *http.Request) {
		version := r.PathValue("version")
		if version != "2.0.0" && version != "0.1.36" {
			http.NotFound(w, r)
			return
		}
		launcher, err := os.ReadFile(os.Args[3])
		if err != nil {
			panic(err)
		}
		_, rest, _ := strings.Cut(string(launcher), "\n")
		io.WriteString(w, ":; version="+version+"\n"+rest)
	})
	mux.HandleFunc("/latest-release", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/tag/2.0.0", http.StatusFound)
	})
	mux.HandleFunc("/tag/2.0.0", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	server := httptest.NewTLSServer(mux)
	defer server.Close()
	certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})
	if err := os.WriteFile(os.Args[1], certificate, 0644); err != nil {
		panic(err)
	}
	// The listener is already bound to an OS-assigned port before publishing it.
	fmt.Println(server.URL)
	io.Copy(io.Discard, os.Stdin)
}
