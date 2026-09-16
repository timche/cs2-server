package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func testServer(t *testing.T) *server {
	t.Helper()
	s, err := newServer(config{
		password: "hunter2",
		secret:   []byte("test-secret"),
		modeFile: filepath.Join(t.TempDir(), "mode"),
	})
	if err != nil {
		t.Fatalf("newServer: %v", err)
	}
	return s
}

func TestSessionTokenRoundTrip(t *testing.T) {
	s := testServer(t)
	exp := time.Now().Add(time.Hour).Unix()
	got, ok := s.verifyToken("session", s.token("session", exp))
	if !ok || got != exp {
		t.Fatalf("verifyToken = %d, %v; want %d, true", got, ok, exp)
	}
}

func TestSessionTokenRejects(t *testing.T) {
	s := testServer(t)
	exp := time.Now().Add(time.Hour).Unix()
	valid := s.token("session", exp)

	tampered := valid[:len(valid)-1] + string(flipLast(valid))
	cases := map[string]string{
		"tampered mac":     tampered,
		"lifted expiry":    strconv.FormatInt(exp+3600, 10) + valid[strings.Index(valid, "."):],
		"no separator":     strings.ReplaceAll(valid, ".", ""),
		"empty":            "",
		"other token kind": s.token("csrf", exp),
		"expired":          s.token("session", time.Now().Add(-time.Second).Unix()),
	}
	for name, token := range cases {
		if _, ok := s.verifyToken("session", token); ok {
			t.Errorf("%s: accepted %q", name, token)
		}
	}
}

func flipLast(s string) byte {
	last := s[len(s)-1]
	if last == 'A' {
		return 'B'
	}
	return 'A'
}

func TestCSRFToken(t *testing.T) {
	s := testServer(t)
	exp := time.Now().Add(time.Hour).Unix()
	token := s.csrfToken(exp)

	if !s.csrfOK(token, exp) {
		t.Fatal("rejected its own token")
	}
	if s.csrfOK(token, exp+1) {
		t.Error("accepted a token issued for another session")
	}
	if s.csrfOK(s.token("session", exp), exp) {
		t.Error("accepted a session token as a CSRF token")
	}
	if s.csrfOK(token[:len(token)-1]+string(flipLast(token)), exp) {
		t.Error("accepted a tampered token")
	}
}

func TestPasswordCompare(t *testing.T) {
	s := testServer(t)
	if !s.passwordOK("hunter2") {
		t.Error("rejected the right password")
	}
	for _, wrong := range []string{"", "hunter", "hunter2 ", "HUNTER2"} {
		if s.passwordOK(wrong) {
			t.Errorf("accepted %q", wrong)
		}
	}
}

func TestWriteModeThenRead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mode")
	if err := writeMode(path, "retakes"); err != nil {
		t.Fatalf("writeMode: %v", err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "retakes\n" {
		t.Errorf("file = %q, want %q", b, "retakes\n")
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o644 {
		t.Errorf("mode = %v, want -rw-r--r--", fi.Mode().Perm())
	}
	if got := readMode(path); got != "retakes" {
		t.Errorf("readMode = %q, want %q", got, "retakes")
	}

	if err := writeMode(path, "matchzy"); err != nil {
		t.Fatalf("rewrite: %v", err)
	}
	if got := readMode(path); got != "matchzy" {
		t.Errorf("after rewrite readMode = %q, want %q", got, "matchzy")
	}
	left, err := filepath.Glob(filepath.Join(filepath.Dir(path), ".mode-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 0 {
		t.Errorf("temp files left behind: %v", left)
	}
}

func TestReadModeUnknown(t *testing.T) {
	dir := t.TempDir()
	if got := readMode(filepath.Join(dir, "absent")); got != "" {
		t.Errorf("absent file = %q, want empty", got)
	}
	for name, content := range map[string]string{
		"garbage":     "surf\n",
		"empty":       "",
		"two modes":   "matchzy retakes\n",
		"long":        strings.Repeat("x", 4096),
		"a directory": "",
	} {
		path := filepath.Join(dir, "mode")
		if name == "a directory" {
			path = dir
		} else if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := readMode(path); got != "" {
			t.Errorf("%s = %q, want empty", name, got)
		}
	}
}

func TestReadModeTrimsWhitespace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mode")
	if err := os.WriteFile(path, []byte("  chatcontrol \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := readMode(path); got != "chatcontrol" {
		t.Errorf("readMode = %q, want %q", got, "chatcontrol")
	}
}

func TestStatusText(t *testing.T) {
	cases := []struct {
		probe error
		mode  string
		want  string
	}{
		{nil, "retakes", "Online · Retakes"},
		{nil, "", "Online · Mode unknown"},
		{errRCONAuth, "matchzy", "RCON password rejected · MatchZy"},
		{io.ErrUnexpectedEOF, "chatcontrol", "Offline · ChatControl"},
	}
	for _, c := range cases {
		if got := statusText(c.probe, c.mode); got != c.want {
			t.Errorf("statusText(%v, %q) = %q, want %q", c.probe, c.mode, got, c.want)
		}
	}
}

func TestRCONPacketRoundTrip(t *testing.T) {
	for _, p := range []rconPacket{
		{id: 1, typ: rconAuth, body: "rconpassword"},
		{id: 2, typ: rconExecCommand, body: "quit"},
		{id: -1, typ: rconAuthResponse, body: ""},
		{id: 7, typ: rconResponseValue, body: strings.Repeat("x", rconMaxBody)},
	} {
		got, err := decodePacket(bytes.NewReader(p.encode()))
		if err != nil {
			t.Fatalf("decode %+v: %v", p, err)
		}
		if got != p {
			t.Errorf("round trip = %+v, want %+v", got, p)
		}
	}
}

func TestRCONAuthFailureID(t *testing.T) {
	wire := rconPacket{id: -1, typ: rconAuthResponse}.encode()
	if size := binary.LittleEndian.Uint32(wire[:4]); size != rconHeaderSize {
		t.Fatalf("size field = %d, want %d", size, rconHeaderSize)
	}
	got, err := decodePacket(bytes.NewReader(wire))
	if err != nil {
		t.Fatal(err)
	}
	if got.id != -1 {
		t.Fatalf("id = %d, want -1", got.id)
	}

	c := &rconConn{conn: fakeConn{r: bytes.NewReader(wire)}}
	if err := c.auth("wrong"); err != errRCONAuth {
		t.Errorf("auth = %v, want %v", err, errRCONAuth)
	}
}

func TestRCONAuthSkipsResponseValue(t *testing.T) {
	var wire bytes.Buffer
	wire.Write(rconPacket{id: rconAuthID, typ: rconResponseValue}.encode())
	wire.Write(rconPacket{id: rconAuthID, typ: rconAuthResponse}.encode())

	c := &rconConn{conn: fakeConn{r: bytes.NewReader(wire.Bytes())}}
	if err := c.auth("right"); err != nil {
		t.Errorf("auth = %v, want nil", err)
	}
}

func TestRCONDecodeRejectsBadLength(t *testing.T) {
	for name, size := range map[string]uint32{
		"under the header": rconHeaderSize - 1,
		"zero":             0,
		"oversized":        rconHeaderSize + rconMaxBody + 1,
		"absurd":           1 << 31,
	} {
		var head [4]byte
		binary.LittleEndian.PutUint32(head[:], size)
		// Only the length is supplied: a reader that tried to allocate first
		// would be caught by the test timing out or by an out-of-memory panic.
		if _, err := decodePacket(bytes.NewReader(head[:])); err == nil {
			t.Errorf("%s: accepted declared size %d", name, size)
		}
	}
}

type fakeConn struct {
	r io.Reader
}

func (c fakeConn) Read(b []byte) (int, error)       { return c.r.Read(b) }
func (c fakeConn) Write(b []byte) (int, error)      { return len(b), nil }
func (c fakeConn) Close() error                     { return nil }
func (c fakeConn) LocalAddr() net.Addr              { return nil }
func (c fakeConn) RemoteAddr() net.Addr             { return nil }
func (c fakeConn) SetDeadline(time.Time) error      { return nil }
func (c fakeConn) SetReadDeadline(time.Time) error  { return nil }
func (c fakeConn) SetWriteDeadline(time.Time) error { return nil }

func TestSignInSetsCookie(t *testing.T) {
	s := testServer(t)
	rec := postForm(s, "/signin", url.Values{"password": {"hunter2"}}, nil)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusSeeOther)
	}
	if sessionCookieOf(rec) == nil {
		t.Fatal("no session cookie")
	}
}

func TestSignInRejectsWrongPassword(t *testing.T) {
	s := testServer(t)
	rec := postForm(s, "/signin", url.Values{"password": {"wrong"}}, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
	if sessionCookieOf(rec) != nil {
		t.Error("set a session cookie for a wrong password")
	}
	if !strings.Contains(rec.Body.String(), "does not match") {
		t.Error("page does not say the password was wrong")
	}
}

func TestModePostNeedsCSRF(t *testing.T) {
	s := testServer(t)
	cookie := signIn(t, s)

	rec := postForm(s, "/mode", url.Values{"mode": {"retakes"}}, cookie)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/?state=expired" {
		t.Fatalf("no token: status %d location %q", rec.Code, rec.Header().Get("Location"))
	}
	if readMode(s.cfg.modeFile) != "" {
		t.Fatal("wrote the mode without a CSRF token")
	}

	exp, _ := s.verifyToken("session", cookie.Value)
	form := url.Values{"mode": {"retakes"}, "csrf": {s.csrfToken(exp)}}
	rec = postForm(s, "/mode", form, cookie)
	// RCON is unreachable in a test, so the restart leg is expected to fail.
	if got := rec.Header().Get("Location"); got != "/?state=restart-failed" {
		t.Fatalf("location = %q, want %q", got, "/?state=restart-failed")
	}
	if got := readMode(s.cfg.modeFile); got != "retakes" {
		t.Fatalf("mode file = %q, want %q", got, "retakes")
	}
}

func TestIndexReportsUnknownModeAndOfflineServer(t *testing.T) {
	s := testServer(t)
	cookie := signIn(t, s)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.AddCookie(cookie)
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "Offline · Mode unknown") {
		t.Error("page does not report an offline server with no mode set")
	}
}

func signIn(t *testing.T, s *server) *http.Cookie {
	t.Helper()
	rec := postForm(s, "/signin", url.Values{"password": {"hunter2"}}, nil)
	c := sessionCookieOf(rec)
	if c == nil {
		t.Fatal("sign in did not set a cookie")
	}
	return c
}

func postForm(s *server, path string, form url.Values, cookie *http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if cookie != nil {
		req.AddCookie(cookie)
	}
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, req)
	return rec
}

func sessionCookieOf(rec *httptest.ResponseRecorder) *http.Cookie {
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookie && c.Value != "" {
			return c
		}
	}
	return nil
}
