// Created By: NeroMorte - bounded LAN discovery; never advertise credentials.
package eqbc

import (
	"fmt"
	"net"
	"strconv"
	"strings"
)

const DiscoveryPort = 2114
const DiscoveryQuery = "TRIUNE_EQBC_DISCOVER_V1 "

func discoveryReply(query string, port int, password bool) string {
	if !strings.HasPrefix(query, DiscoveryQuery) || port < 1 || port > 65535 {
		return ""
	}
	nonce := strings.TrimPrefix(query, DiscoveryQuery)
	if len(nonce) < 1 || len(nonce) > 32 {
		return ""
	}
	for _, c := range nonce {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return ""
		}
	}
	protected := 0
	if password {
		protected = 1
	}
	return fmt.Sprintf("TRIUNE_EQBC_SERVER_V1 %s %d %d", nonce, port, protected)
}

// Starts only after TCP has bound, advertises its actual port, and follows its lifetime.
func startDiscovery(tcp net.Addr, password bool) (func(), error) {
	host, rawPort, err := net.SplitHostPort(tcp.String())
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(rawPort)
	if err != nil {
		return nil, err
	}
	ip := net.ParseIP(host)
	if ip == nil || ip.To4() == nil {
		return nil, fmt.Errorf("LAN discovery requires an IPv4 listener")
	}
	sock, err := net.ListenUDP("udp4", &net.UDPAddr{IP: ip, Port: DiscoveryPort})
	if err != nil {
		return nil, err
	}
	go func() {
		buf := make([]byte, 256)
		for {
			n, from, err := sock.ReadFromUDP(buf)
			if err != nil {
				return
			}
			if reply := discoveryReply(string(buf[:n]), port, password); reply != "" {
				_, _ = sock.WriteToUDP([]byte(reply), from)
			}
		}
	}()
	return func() { _ = sock.Close() }, nil
}
