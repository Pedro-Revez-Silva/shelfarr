//go:build e2e

package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const upstreamHost = "openlibrary.org:443"

type record struct {
	Kind      string              `json:"kind"`
	Target    string              `json:"target,omitempty"`
	Path      string              `json:"path,omitempty"`
	Query     map[string][]string `json:"query,omitempty"`
	Headers   map[string][]string `json:"headers,omitempty"`
	Cancelled bool                `json:"cancelled,omitempty"`
	At        string              `json:"at"`
}

type journal struct {
	mutex sync.Mutex
	file  *os.File
}

func (j *journal) add(entry record) {
	entry.At = time.Now().UTC().Format(time.RFC3339Nano)
	encoded, _ := json.Marshal(entry)
	j.mutex.Lock()
	defer j.mutex.Unlock()
	j.file.Write(append(encoded, '\n'))
}

type connections chan net.Conn

func (c connections) Accept() (net.Conn, error) {
	conn, ok := <-c
	if !ok {
		return nil, net.ErrClosed
	}
	return conn, nil
}

func (c connections) Close() error   { return nil }
func (c connections) Addr() net.Addr { return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)} }

func certificates(dir string) (*tls.Config, string, error) {
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, "", err
	}
	now := time.Now()
	caTemplate := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Shelfarr e2e test authority"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(24 * time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		return nil, "", err
	}
	ca, err := x509.ParseCertificate(caDER)
	if err != nil {
		return nil, "", err
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, "", err
	}
	leafTemplate := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "openlibrary.org"}, DNSNames: []string{"openlibrary.org"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(24 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, ca, &leafKey.PublicKey, caKey)
	if err != nil {
		return nil, "", err
	}
	path := filepath.Join(dir, "fake-openlibrary-ca.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}), 0o600); err != nil {
		return nil, "", err
	}
	config := &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{leafDER}, PrivateKey: leafKey}}, NextProtos: []string{"http/1.1"}, MinVersion: tls.VersionTLS12}
	return config, path, nil
}

func searchHandler(log *journal, recorded []byte) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		entry := record{Kind: "request", Path: r.URL.Path, Query: r.URL.Query(), Headers: r.Header.Clone()}
		if r.URL.Path != "/search.json" || r.Method != http.MethodGet {
			log.add(entry)
			http.NotFound(w, r)
			return
		}
		query := r.URL.Query().Get("q")
		json := func(status int, body string) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			w.Write([]byte(body))
		}
		switch {
		case strings.HasPrefix(query, "hang"):
			select {
			case <-r.Context().Done():
				entry.Cancelled = true
			case <-time.After(30 * time.Second):
			}
			log.add(entry)
			return
		case strings.HasPrefix(query, "slow"):
			select {
			case <-r.Context().Done():
				entry.Cancelled = true
				log.add(entry)
				return
			case <-time.After(2500 * time.Millisecond):
			}
		}
		log.add(entry)
		switch {
		case strings.HasPrefix(query, "empty"):
			json(http.StatusOK, `{"numFound":0,"start":0,"docs":[]}`)
		case strings.HasPrefix(query, "limit"):
			w.Header().Set("Retry-After", "30")
			json(http.StatusTooManyRequests, `{"error":"slow down"}`)
		case strings.HasPrefix(query, "broken"):
			json(http.StatusInternalServerError, `{"error":"Internal Server Error, query `+query+`"}`)
		case strings.HasPrefix(query, "garbage"):
			w.Header().Set("Content-Type", "text/html")
			w.Write([]byte("<html><body>maintenance</body></html>"))
		case strings.HasPrefix(query, "redirect"):
			http.Redirect(w, r, "http://127.0.0.1:9/elsewhere", http.StatusFound)
		case strings.HasPrefix(query, "huge"):
			json(http.StatusOK, `{"docs":[],"pad":"`+strings.Repeat("a", 2<<20)+`"}`)
		default:
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.Write(recorded)
		}
	})
}

func proxy(log *journal, upstream connections, tlsConfig *tls.Config) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodConnect || r.Host != upstreamHost {
			log.add(record{Kind: "refused", Target: r.Method + " " + r.Host + r.URL.String()})
			http.Error(w, "only CONNECT openlibrary.org:443", http.StatusForbidden)
			return
		}
		hijacker, ok := w.(http.Hijacker)
		if !ok {
			http.Error(w, "no hijack", http.StatusInternalServerError)
			return
		}
		conn, buffered, err := hijacker.Hijack()
		if err != nil {
			return
		}
		log.add(record{Kind: "connect", Target: r.Host})
		buffered.WriteString("HTTP/1.1 200 Connection established\r\n\r\n")
		buffered.Flush()
		upstream <- tls.Server(bufferedConn{Conn: conn, reader: buffered.Reader}, tlsConfig)
	})
}

type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (b bufferedConn) Read(p []byte) (int, error) { return b.reader.Read(p) }

func main() {
	dir := flag.String("dir", "", "directory for the test authority and the request journal")
	response := flag.String("response", "", "recorded search.json answer")
	flag.Parse()
	if *dir == "" || *response == "" {
		fmt.Fprintln(os.Stderr, "usage: fake-openlibrary -dir DIR -response FILE")
		os.Exit(2)
	}
	recorded, err := os.ReadFile(*response)
	if err != nil || !json.Valid(recorded) {
		fmt.Fprintln(os.Stderr, "unusable response file")
		os.Exit(2)
	}
	tlsConfig, caPath, err := certificates(*dir)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	file, err := os.OpenFile(filepath.Join(*dir, "fake-openlibrary.jsonl"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	log := &journal{file: file}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	upstream := make(connections)
	go (&http.Server{Handler: searchHandler(log, recorded), ReadHeaderTimeout: 5 * time.Second}).Serve(upstream)
	server := &http.Server{Handler: proxy(log, upstream, tlsConfig), ReadHeaderTimeout: 5 * time.Second}
	ready, _ := json.Marshal(map[string]string{"proxy": "http://" + listener.Addr().String(), "ca": caPath, "journal": file.Name()})
	fmt.Println(string(ready))
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, os.Interrupt)
	go func() {
		<-stop
		server.Close()
	}()
	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
