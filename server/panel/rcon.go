package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"time"
)

const (
	rconAuth          = 3
	rconExecCommand   = 2
	rconResponseValue = 0
	// Same number as rconExecCommand: the protocol reuses 2 in the server's
	// direction for the reply to an auth.
	rconAuthResponse = 2

	// Size counts everything after it: two int32 fields and two NULs.
	rconHeaderSize = 10
	rconMaxBody    = 4096

	rconAuthID = 1
	rconCmdID  = 2

	// A server that keeps sending response values instead of the auth reply
	// would otherwise spin until the deadline.
	rconMaxAuthPackets = 8
)

var errRCONAuth = errors.New("rcon: password rejected")

type rconPacket struct {
	id   int32
	typ  int32
	body string
}

func (p rconPacket) encode() []byte {
	b := make([]byte, 0, 4+rconHeaderSize+len(p.body))
	b = binary.LittleEndian.AppendUint32(b, uint32(rconHeaderSize+len(p.body)))
	b = binary.LittleEndian.AppendUint32(b, uint32(p.id))
	b = binary.LittleEndian.AppendUint32(b, uint32(p.typ))
	b = append(b, p.body...)
	return append(b, 0, 0)
}

func decodePacket(r io.Reader) (rconPacket, error) {
	var head [4]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return rconPacket{}, err
	}
	size := binary.LittleEndian.Uint32(head[:])
	if size < rconHeaderSize || size > rconHeaderSize+rconMaxBody {
		return rconPacket{}, fmt.Errorf("rcon: declared packet size %d out of range", size)
	}
	buf := make([]byte, size)
	if _, err := io.ReadFull(r, buf); err != nil {
		return rconPacket{}, err
	}
	body := buf[8:]
	if i := bytes.IndexByte(body, 0); i >= 0 {
		body = body[:i]
	}
	return rconPacket{
		id:   int32(binary.LittleEndian.Uint32(buf[0:4])),
		typ:  int32(binary.LittleEndian.Uint32(buf[4:8])),
		body: string(body),
	}, nil
}

type rconConn struct {
	conn net.Conn
}

func rconDial(addr, password string, timeout time.Duration) (*rconConn, error) {
	if addr == "" {
		return nil, errors.New("rcon: no address configured")
	}
	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return nil, err
	}
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		conn.Close()
		return nil, err
	}
	c := &rconConn{conn: conn}
	if err := c.auth(password); err != nil {
		conn.Close()
		return nil, err
	}
	return c, nil
}

func (c *rconConn) Close() error { return c.conn.Close() }

func (c *rconConn) auth(password string) error {
	if _, err := c.conn.Write(rconPacket{id: rconAuthID, typ: rconAuth, body: password}.encode()); err != nil {
		return err
	}
	for range rconMaxAuthPackets {
		p, err := decodePacket(c.conn)
		if err != nil {
			return err
		}
		if p.typ == rconResponseValue {
			continue
		}
		switch p.id {
		case -1:
			return errRCONAuth
		case rconAuthID:
			return nil
		default:
			return fmt.Errorf("rcon: auth answered with request id %d", p.id)
		}
	}
	return errors.New("rcon: no auth reply")
}

// send does not wait for a reply: the one command the panel sends is quit, and
// the server dies without answering it.
func (c *rconConn) send(cmd string) error {
	_, err := c.conn.Write(rconPacket{id: rconCmdID, typ: rconExecCommand, body: cmd}.encode())
	return err
}
