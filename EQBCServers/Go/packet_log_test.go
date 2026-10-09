// Created By: NeroMorte - command filtering must not hide chat, ordinary commands or errors.
package eqbc

import (
	"bufio"
	"bytes"
	"github.com/fatih/color"
	"net"
	"testing"
	"time"
)

func TestPacketDisplay(t *testing.T) {
	var output bytes.Buffer
	old := color.Output
	color.Output = &output
	defer func() { color.Output = old }()
	server := NewServer(ServerConfig{Verbose: true, NoTimestamp: true})
	server.logCommand("//ac net _eqbc Name_1.1.1.abcdef", "internal")
	if output.Len() != 0 {
		t.Fatal("internal packet leaked with default settings")
	}
	server.logCommand("//ac net Scuranima /echo test", "ordinary")
	server.Log("failed to send to client")
	server.Log("chat mentions //ac net _eqbc")
	if got := output.String(); got != "ordinary\nfailed to send to client\nchat mentions //ac net _eqbc\n" {
		t.Fatalf("visible logs changed: %q", got)
	}
	output.Reset()
	server = NewServer(ServerConfig{ShowInternalPackets: true, NoTimestamp: true})
	server.logCommand("//ac net _eqbc Name_1.1.1.abcdef", "internal")
	if output.String() != "internal\n" {
		t.Fatal("debug packet display missing")
	}
}

func TestPacketPrefix(t *testing.T) {
	for _, command := range []string{" //ac net _eqbc x ", "/AC BOXNET _EQBC x"} {
		if !isTriunePacket(command) {
			t.Fatalf("packet not recognized: %q", command)
		}
	}
	for _, command := range []string{"hello //ac net _eqbc x", "//echo /ac net _eqbc x", "//ac net _eqbc", "//ac net _eqbcOther x", "//ac net all assist chase"} {
		if isTriunePacket(command) {
			t.Fatalf("ordinary text suppressed: %q", command)
		}
	}
}

// Created By: NeroMorte - hiding delivery logs must still forward the exact packet.
func TestQuietPacketForwarding(t *testing.T) {
	var output bytes.Buffer
	old := color.Output
	color.Output = &output
	defer func() { color.Output = old }()
	server := NewServer(ServerConfig{Verbose: true, NoTimestamp: true})
	writer, reader := net.Pipe()
	defer writer.Close()
	defer reader.Close()
	reader.SetReadDeadline(time.Now().Add(time.Second))
	server.registerClient(writer, 1, "Receiver")
	payload := "//ac net _eqbc Sender_1.1.1.abcdef"
	received := make(chan string, 1)
	go func() {
		line, err := bufio.NewReader(reader).ReadString('\n')
		if err != nil {
			received <- err.Error()
			return
		}
		received <- line
	}()
	server.broadcastOthers(2, "Sender", payload)
	if line := <-received; line != "<Sender> Receiver "+payload+"\n" {
		t.Fatalf("forwarded packet changed: %q", line)
	}
	if output.Len() != 0 {
		t.Fatalf("internal delivery log leaked: %q", output.String())
	}
}
