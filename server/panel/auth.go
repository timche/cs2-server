package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	sessionCookie = "cs2panel"
	sessionLife   = 90 * 24 * time.Hour

	signInDelay  = 300 * time.Millisecond
	signInTries  = 10
	signInWindow = 10 * time.Minute
)

func (s *server) passwordOK(submitted string) bool {
	// Hashing both sides keeps the comparison from leaking the password length.
	got := sha256.Sum256([]byte(submitted))
	want := sha256.Sum256([]byte(s.cfg.password))
	return subtle.ConstantTimeCompare(got[:], want[:]) == 1
}

func (s *server) mac(msg string) string {
	m := hmac.New(sha256.New, s.cfg.secret)
	m.Write([]byte(msg))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func (s *server) token(kind string, expires int64) string {
	exp := strconv.FormatInt(expires, 10)
	return exp + "." + s.mac(kind+":"+exp)
}

func (s *server) verifyToken(kind, token string) (int64, bool) {
	exp, mac, found := strings.Cut(token, ".")
	if !found {
		return 0, false
	}
	if !hmac.Equal([]byte(mac), []byte(s.mac(kind+":"+exp))) {
		return 0, false
	}
	expires, err := strconv.ParseInt(exp, 10, 64)
	if err != nil || time.Now().Unix() >= expires {
		return 0, false
	}
	return expires, true
}

func (s *server) session(r *http.Request) (int64, bool) {
	c, err := r.Cookie(sessionCookie)
	if err != nil {
		return 0, false
	}
	return s.verifyToken("session", c.Value)
}

func (s *server) setSession(w http.ResponseWriter, r *http.Request) {
	expires := time.Now().Add(sessionLife)
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    s.token("session", expires.Unix()),
		Path:     "/",
		Expires:  expires,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   overTLS(r),
	})
}

func (s *server) clearSession(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Path:     "/",
		MaxAge:   -1,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   overTLS(r),
	})
}

// The panel publishes on 127.0.0.1 and is reached only through the Cloudflare
// tunnel, which sets this header itself and strips any the client sent.
// Trusting it on a directly reachable listener would let anyone claim TLS.
func overTLS(r *http.Request) bool {
	if r.TLS != nil {
		return true
	}
	return strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}

// csrfToken is bound to the session's expiry, so a token only works with the
// cookie it was issued alongside.
func (s *server) csrfToken(sessionExpires int64) string {
	return s.token("csrf", sessionExpires)
}

func (s *server) csrfOK(token string, sessionExpires int64) bool {
	expires, ok := s.verifyToken("csrf", token)
	return ok && expires == sessionExpires
}

type limiter struct {
	mu   sync.Mutex
	hits map[string][]time.Time
}

func newLimiter() *limiter { return &limiter{hits: map[string][]time.Time{}} }

func (l *limiter) allow(key string, tries int, window time.Duration) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	cutoff := time.Now().Add(-window)
	for k, ts := range l.hits {
		kept := ts[:0]
		for _, t := range ts {
			if t.After(cutoff) {
				kept = append(kept, t)
			}
		}
		if len(kept) == 0 {
			delete(l.hits, k)
			continue
		}
		l.hits[k] = kept
	}
	if len(l.hits[key]) >= tries {
		return false
	}
	l.hits[key] = append(l.hits[key], time.Now())
	return true
}

// Keyed on the peer address rather than on X-Forwarded-For: a forwarded
// address is attacker-chosen and would hand out a fresh budget per attempt.
func peerKey(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
