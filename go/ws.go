package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const (
	bufLen      = 4096 * 4
	idleTimeout = 180 * time.Second // sama dengan Python: 60 putaran x 3 detik tanpa data
	passHeader  = ""                // PASS kosong seperti versi Python
	// Sama persis dengan RESPONSE di versi Python.
	wsResponse = "HTTP/1.1 101 WebSocket <font color=\"#00BFFF\">By Chanel-Og</font>\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: foo\r\n\r\n"
)

type wsConfig struct {
	Name         string
	Title        string
	DefaultPort  int
	DefaultHost  string
	StripPreface bool // hanya ws-openssh: buang "HTTP/1.1 200 OK" palsu dari payload [split]
}

func runWS(cfg wsConfig, args []string) {
	fs := flag.NewFlagSet(cfg.Name, flag.ExitOnError)
	bind := fs.String("b", "0.0.0.0", "alamat bind")
	fs.StringVar(bind, "bind", "0.0.0.0", "alamat bind")
	port := fs.Int("p", cfg.DefaultPort, "port")
	fs.IntVar(port, "port", cfg.DefaultPort, "port")
	fs.Usage = func() {
		fmt.Printf("Usage: %s -p <port>\n       %s -b <bindAddr> -p <port>\n", cfg.Name, cfg.Name)
	}
	_ = fs.Parse(args)
	// Argumen posisional (cara systemd): ws-dropbear 2095
	if fs.NArg() > 0 {
		p, err := strconv.Atoi(fs.Arg(0))
		if err != nil {
			fmt.Fprintf(os.Stderr, "port tidak valid: %s\n", fs.Arg(0))
			os.Exit(2)
		}
		*port = p
	}

	ln, err := net.Listen("tcp4", net.JoinHostPort(*bind, strconv.Itoa(*port)))
	if err != nil {
		log.Fatalf("gagal listen %s:%d: %v", *bind, *port, err)
	}
	fmt.Printf("\n:------- %s -------:\n\n", cfg.Title)
	fmt.Printf("Listening addr: %s\nListening port: %d\n\n", *bind, *port)
	fmt.Printf(":--------------------------------------:\n\n")

	for {
		c, err := ln.Accept()
		if err != nil {
			time.Sleep(50 * time.Millisecond)
			continue
		}
		go handleWS(c, cfg)
	}
}

// findHeader meniru versi Python: cari "Nama: " lalu ambil sampai CRLF.
func findHeader(head, header string) string {
	i := strings.Index(head, header+": ")
	if i == -1 {
		return ""
	}
	rest := head[i+len(header)+2:]
	j := strings.Index(rest, "\r\n")
	if j == -1 {
		return ""
	}
	return rest[:j]
}

func handleWS(client net.Conn, cfg wsConfig) {
	defer client.Close()

	buf := make([]byte, bufLen)
	client.SetReadDeadline(time.Now().Add(30 * time.Second))
	n, err := client.Read(buf)
	if err != nil || n == 0 {
		return
	}
	head := string(buf[:n])

	hostPort := findHeader(head, "X-Real-Host")
	if hostPort == "" {
		hostPort = cfg.DefaultHost
	}
	if findHeader(head, "X-Split") != "" {
		client.SetReadDeadline(time.Now().Add(30 * time.Second))
		client.Read(buf) // buang paket kedua, seperti versi Python
	}

	passwd := findHeader(head, "X-Pass")
	switch {
	case passHeader != "" && passwd == passHeader:
	case passHeader != "" && passwd != passHeader:
		client.Write([]byte("HTTP/1.1 400 WrongPass!\r\n\r\n"))
		return
	case strings.HasPrefix(hostPort, "127.0.0.1") || strings.HasPrefix(hostPort, "localhost"):
	default:
		client.Write([]byte("HTTP/1.1 403 Forbidden!\r\n\r\n"))
		return
	}

	host, port := hostPort, 22
	if i := strings.Index(hostPort, ":"); i != -1 {
		p, err := strconv.Atoi(hostPort[i+1:])
		if err != nil {
			return
		}
		host, port = hostPort[:i], p
	}
	target, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), 30*time.Second)
	if err != nil {
		log.Printf("Connection: %s - CONNECT %s - error: %v", client.RemoteAddr(), hostPort, err)
		return
	}
	defer target.Close()

	client.SetReadDeadline(time.Time{})
	client.SetWriteDeadline(time.Now().Add(30 * time.Second))
	if _, err := client.Write([]byte(wsResponse)); err != nil {
		return
	}
	log.Printf("Connection: %s - CONNECT %s", client.RemoteAddr(), hostPort)

	var strip *prefaceStripper
	if cfg.StripPreface {
		strip = &prefaceStripper{}
	}
	relay(client, target, strip)
}

// prefaceStripper = strip_preface() di ws-openssh versi Python.
type prefaceStripper struct {
	pre  []byte
	done bool
}

var httpPrefix = []byte("HTTP/")

func (s *prefaceStripper) strip(data []byte) []byte {
	if s.done {
		return data
	}
	buf := make([]byte, 0, len(s.pre)+len(data))
	buf = append(buf, s.pre...)
	buf = append(buf, data...)
	for bytes.HasPrefix(buf, httpPrefix) || (len(buf) < 5 && bytes.HasPrefix(httpPrefix, buf)) {
		i := bytes.Index(buf, []byte("\r\n\r\n"))
		if i == -1 {
			s.pre = buf
			return nil
		}
		buf = buf[i+4:]
	}
	s.pre = nil
	s.done = true
	return buf
}

// relay menyalin dua arah. Koneksi ditutup kalau salah satu sisi putus atau
// tidak ada data di kedua arah selama idleTimeout.
func relay(client, target net.Conn, strip *prefaceStripper) {
	var last atomic.Int64
	last.Store(time.Now().UnixNano())
	done := make(chan struct{}, 2)

	pump := func(dst, src net.Conn, filter *prefaceStripper) {
		defer func() { done <- struct{}{} }()
		b := make([]byte, bufLen)
		for {
			src.SetReadDeadline(time.Now().Add(idleTimeout))
			n, err := src.Read(b)
			if n > 0 {
				last.Store(time.Now().UnixNano())
				data := b[:n]
				if filter != nil {
					data = filter.strip(data)
				}
				if len(data) > 0 {
					dst.SetWriteDeadline(time.Now().Add(idleTimeout))
					if _, werr := dst.Write(data); werr != nil {
						return
					}
				}
			}
			if err != nil {
				var ne net.Error
				if errors.As(err, &ne) && ne.Timeout() &&
					time.Since(time.Unix(0, last.Load())) < idleTimeout {
					continue // arah sebaliknya masih aktif
				}
				return
			}
		}
	}

	go pump(target, client, strip) // client -> target (pakai filter bila ada)
	go pump(client, target, nil)   // target -> client
	<-done
	client.Close()
	target.Close()
	<-done
}
