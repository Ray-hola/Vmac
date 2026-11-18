package cage

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"strconv"
	"time"
)

// The UDP socket may only talk to the local managed Mihomo relay. The SOCKS
// control connection and datagram socket share the lifetime of one gate flow.
func (e *Egress) dialUDP(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
	if !e.Allows("udp", dst) {
		return nil, ErrGateClosed
	}
	ctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	control, err := e.connect.DialContext(ctx, "tcp", e.upstream.Host)
	if err != nil {
		return nil, err
	}
	stop := context.AfterFunc(ctx, func() { _ = control.Close() })
	defer stop()
	success := false
	defer func() {
		if !success {
			_ = control.Close()
		}
	}()
	deadline, _ := ctx.Deadline()
	if err = control.SetDeadline(deadline); err != nil {
		return nil, err
	}
	reader := bufio.NewReader(control)

	password, _ := e.upstream.User.Password()
	username := e.upstream.User.Username()
	if len(username) == 0 || len(username) > 255 || len(password) == 0 || len(password) > 255 {
		return nil, errors.New("invalid local SOCKS authentication")
	}
	if err = socksExpect(control, reader, []byte{5, 1, 2}, []byte{5, 2}); err != nil {
		return nil, err
	}
	auth := append([]byte{1, byte(len(username))}, username...)
	auth = append(append(auth, byte(len(password))), password...)
	if err = socksExpect(control, reader, auth, []byte{1, 0}); err != nil {
		return nil, err
	}
	// RFC 1928 UDP ASSOCIATE, zero address asks the relay to learn the source.
	if err = socksExpect(control, reader, []byte{5, 3, 0, 1, 0, 0, 0, 0, 0, 0}, []byte{5, 0, 0, 1}); err != nil {
		return nil, err
	}
	var relay [6]byte
	if _, err = io.ReadFull(reader, relay[:]); err != nil {
		return nil, err
	}
	ip := netip.AddrFrom4([4]byte(relay[:4]))
	port := binary.BigEndian.Uint16(relay[4:])
	if port == 0 || (!ip.IsLoopback() && !ip.IsUnspecified()) {
		return nil, errors.New("SOCKS refused: UDP relay is not on loopback")
	}
	packet, err := (&net.Dialer{}).DialContext(ctx, "udp4", net.JoinHostPort(e.upstream.Hostname(), strconv.Itoa(int(port))))
	if err != nil {
		return nil, err
	}
	if !stop() || ctx.Err() != nil {
		_ = packet.Close()
		return nil, context.DeadlineExceeded
	}
	if err = control.SetDeadline(time.Time{}); err != nil {
		_ = packet.Close()
		return nil, err
	}
	address := dst.Addr().Unmap().As4()
	header := [10]byte{0, 0, 0, 1, address[0], address[1], address[2], address[3]}
	binary.BigEndian.PutUint16(header[8:], dst.Port())
	tunnel := &socksDatagrams{Conn: packet, control: control, header: header}
	success = true
	go func() {
		// No more data is expected on the SOCKS TCP channel after association.
		_, _ = reader.ReadByte()
		_ = tunnel.Close()
	}()
	return tunnel, nil
}

func socksExpect(c net.Conn, r io.Reader, request, response []byte) error {
	if _, err := c.Write(request); err != nil {
		return err
	}
	got := make([]byte, len(response))
	if _, err := io.ReadFull(r, got); err != nil {
		return err
	}
	if !bytes.Equal(got, response) {
		return errors.New("local SOCKS server rejected UDP association")
	}
	return nil
}

type socksDatagrams struct {
	net.Conn
	control net.Conn
	header  [10]byte
}

func (c *socksDatagrams) Write(payload []byte) (int, error) {
	if len(payload) > 65507-len(c.header) {
		return 0, errors.New("UDP datagram exceeds relay size")
	}
	wire := make([]byte, len(c.header)+len(payload))
	copy(wire, c.header[:])
	copy(wire[len(c.header):], payload)
	if _, err := c.Conn.Write(wire); err != nil {
		return 0, err
	}
	return len(payload), nil
}

func (c *socksDatagrams) Read(payload []byte) (int, error) {
	wire := make([]byte, len(c.header)+len(payload)+1)
	for {
		n, err := c.Conn.Read(wire)
		if err != nil {
			return 0, err
		}
		// Reject fragments and replies for any other address or port.
		if n >= len(c.header) && n < len(wire) && bytes.Equal(wire[:len(c.header)], c.header[:]) {
			return copy(payload, wire[len(c.header):n]), nil
		}
	}
}

func (c *socksDatagrams) Close() error {
	_ = c.control.Close()
	return c.Conn.Close()
}
