package cage

import (
	"bytes"
	"io"
	"net"
	"net/netip"
	"net/url"
	"testing"
	"time"
)

func TestManagedUDPUsesOnlyAuthenticatedLoopbackRelay(t *testing.T) {
	tcp, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer tcp.Close()
	packet, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer packet.Close()
	defer packet.SetDeadline(time.Now())
	tcp.(*net.TCPListener).SetDeadline(time.Now().Add(4 * time.Second))
	packet.SetDeadline(time.Now().Add(4 * time.Second))
	want := []byte{0, 0, 0, 1, 1, 1, 1, 1, 0, 53, 'q'}
	probe := make(chan []byte, 1)
	go func() {
		c, err := tcp.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(4 * time.Second))
		for _, exchange := range []struct{ request, reply []byte }{
			{[]byte{5, 1, 2}, []byte{5, 2}},
			{[]byte{1, 4, 'c', 'a', 'g', 'e', 1, 'p'}, []byte{1, 0}},
			{[]byte{5, 3, 0, 1, 0, 0, 0, 0, 0, 0}, []byte{5, 0, 0, 1, 127, 0, 0, 1, byte(packet.LocalAddr().(*net.UDPAddr).Port >> 8), byte(packet.LocalAddr().(*net.UDPAddr).Port)}},
		} {
			request := make([]byte, len(exchange.request))
			if _, err := io.ReadFull(c, request); err != nil || !bytes.Equal(request, exchange.request) {
				return
			}
			if _, err := c.Write(exchange.reply); err != nil {
				return
			}
		}
		buffer := make([]byte, 128)
		n, source, err := packet.ReadFromUDP(buffer)
		if err != nil {
			return
		}
		probe <- bytes.Clone(buffer[:n])
		bad := append(bytes.Clone(want[:10]), 'x')
		bad[2] = 1 // fragmented responses are not accepted
		packet.WriteToUDP(bad, source)
		packet.WriteToUDP(append(bytes.Clone(want[:10]), 'r'), source)
		_, _ = c.Read(buffer)
	}()

	upstream := &url.URL{Scheme: "socks5", Host: tcp.Addr().String(), User: url.UserPassword("cage", "p")}
	egress := &Egress{udp: true, upstream: upstream, connect: &net.Dialer{}}
	for _, raw := range []string{"127.0.0.1:53", "192.168.1.1:53", "[2001:4860:4860::8888]:53"} {
		if c, err := egress.dialUDP(t.Context(), netip.MustParseAddrPort(raw)); err == nil {
			c.Close()
			t.Fatalf("private or unsupported destination accepted: %s", raw)
		}
	}
	c, err := egress.dialUDP(t.Context(), netip.MustParseAddrPort("1.1.1.1:53"))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(3 * time.Second))
	if n, err := c.Write([]byte("q")); err != nil || n != 1 {
		t.Fatalf("UDP write: %d, %v", n, err)
	}
	response := make([]byte, 16)
	if n, err := c.Read(response); err != nil || string(response[:n]) != "r" {
		t.Fatalf("UDP read: %d, %v", n, err)
	}
	if got := <-probe; !bytes.Equal(got, want) {
		t.Fatalf("unexpected SOCKS header: %v", got)
	}
}
