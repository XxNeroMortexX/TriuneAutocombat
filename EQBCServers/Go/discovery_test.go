// Created By: NeroMorte - verify protocol boundaries and live UDP discovery.
package eqbc

import (
	"net"
	"strings"
	"testing"
	"time"
)

func TestDiscoveryReply(t *testing.T) {
	if got := discoveryReply(DiscoveryQuery+"123abc", 4321, true); got != "TRIUNE_EQBC_SERVER_V1 123abc 4321 1" {
		t.Fatal(got)
	}
	for _, bad := range []string{"", "wrong 123abc", DiscoveryQuery, DiscoveryQuery + strings.Repeat("a", 33), DiscoveryQuery + "x;password", DiscoveryQuery + "123 abc"} {
		if discoveryReply(bad, 2113, false) != "" {
			t.Fatal("accepted malformed query", bad)
		}
	}
	if discoveryReply(DiscoveryQuery+"1", 0, false) != "" {
		t.Fatal("invalid port")
	}
}
func TestDiscoveryUDP(t *testing.T) {
	tcp, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer tcp.Close()
	closeDiscovery, err := startDiscovery(tcp.Addr(), false)
	if err != nil {
		t.Fatal(err)
	}
	defer closeDiscovery()
	client, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: DiscoveryPort})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(time.Second))
	_, err = client.Write([]byte(DiscoveryQuery + "abcd"))
	if err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 256)
	n, err := client.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	port := tcp.Addr().(*net.TCPAddr).Port
	if string(buf[:n]) != discoveryReply(DiscoveryQuery+"abcd", port, false) {
		t.Fatal(string(buf[:n]))
	}
}
