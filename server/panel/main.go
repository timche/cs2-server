package main

import (
	"embed"
	"encoding/json"
	"errors"
	"html/template"
	"log"
	"net/http"
	"os"
	"time"
)

//go:embed page.html
var pageFS embed.FS

const (
	rconProbeTimeout   = 3 * time.Second
	rconRestartTimeout = 5 * time.Second
)

type config struct {
	password string
	secret   []byte
	rconAddr string
	rconPW   string
	modeFile string
}

type server struct {
	cfg     config
	page    *template.Template
	signIns *limiter
}

func main() {
	log.SetFlags(0)
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("panel: %v", err)
	}
	s, err := newServer(cfg)
	if err != nil {
		log.Fatalf("panel: %v", err)
	}
	httpSrv := &http.Server{
		Addr:              ":8080",
		Handler:           s.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("panel listening on %s", httpSrv.Addr)
	log.Fatal(httpSrv.ListenAndServe())
}

func loadConfig() (config, error) {
	cfg := config{
		password: os.Getenv("PANEL_PASSWORD"),
		secret:   []byte(os.Getenv("PANEL_SECRET")),
		rconAddr: os.Getenv("CS2_RCON_ADDR"),
		rconPW:   os.Getenv("CS2_RCONPW"),
		modeFile: os.Getenv("PANEL_MODE_FILE"),
	}
	if cfg.modeFile == "" {
		cfg.modeFile = "/control/mode"
	}
	if cfg.password == "" {
		return cfg, errors.New("PANEL_PASSWORD is empty")
	}
	if len(cfg.secret) == 0 {
		return cfg, errors.New("PANEL_SECRET is empty")
	}
	return cfg, nil
}

func newServer(cfg config) (*server, error) {
	page, err := template.ParseFS(pageFS, "page.html")
	if err != nil {
		return nil, err
	}
	return &server{cfg: cfg, page: page, signIns: newLimiter()}, nil
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.handleIndex)
	mux.HandleFunc("POST /signin", s.handleSignIn)
	mux.HandleFunc("POST /signout", s.handleSignOut)
	mux.HandleFunc("POST /mode", s.handleMode)
	mux.HandleFunc("GET /status", s.handleStatus)
	return mux
}

type modeChoice struct {
	mode
	Checked bool
}

type pageData struct {
	SignedIn   bool
	CSRF       string
	Modes      []modeChoice
	Online     bool
	Status     string
	Restarting bool
	Error      string
}

func statusText(probe error, name string) string {
	label := modeLabel(name)
	switch {
	case probe == nil:
		return "Online · " + label
	case errors.Is(probe, errRCONAuth):
		return "RCON password rejected · " + label
	default:
		return "Offline · " + label
	}
}

func (s *server) probeRCON() error {
	c, err := rconDial(s.cfg.rconAddr, s.cfg.rconPW, rconProbeTimeout)
	if err != nil {
		return err
	}
	return c.Close()
}

func (s *server) render(w http.ResponseWriter, status int, data pageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if err := s.page.Execute(w, data); err != nil {
		log.Printf("panel: render: %v", err)
	}
}

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	expires, ok := s.session(r)
	if !ok {
		s.render(w, http.StatusOK, pageData{Error: signInError(r.URL.Query().Get("state"))})
		return
	}

	current := readMode(s.cfg.modeFile)
	probe := s.probeRCON()
	data := pageData{
		SignedIn: true,
		CSRF:     s.csrfToken(expires),
		Online:   probe == nil,
		Status:   statusText(probe, current),
	}
	for _, m := range modes {
		data.Modes = append(data.Modes, modeChoice{mode: m, Checked: m.Name == current})
	}

	switch r.URL.Query().Get("state") {
	case "restarting":
		data.Restarting = true
		data.Online = false
		data.Status = "Restarting…"
	case "save-failed":
		data.Error = "Unable to save the mode. Nothing changed — try again."
	case "restart-failed":
		data.Error = "The mode is saved, but the restart command did not reach the server. Try again, or restart the container yourself."
	case "no-mode":
		data.Error = "Choose a mode first."
	}
	s.render(w, http.StatusOK, data)
}

func signInError(state string) string {
	if state == "expired" {
		return "Your session ended. Sign in and try again."
	}
	return ""
}

func (s *server) handleSignIn(w http.ResponseWriter, r *http.Request) {
	time.Sleep(signInDelay)
	if !s.signIns.allow(peerKey(r), signInTries, signInWindow) {
		s.render(w, http.StatusTooManyRequests, pageData{
			Error: "Too many attempts. Wait ten minutes and try again.",
		})
		return
	}
	if !s.passwordOK(r.FormValue("password")) {
		s.render(w, http.StatusUnauthorized, pageData{
			Error: "That password does not match. Check it and try again.",
		})
		return
	}
	s.setSession(w, r)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *server) handleSignOut(w http.ResponseWriter, r *http.Request) {
	s.clearSession(w, r)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *server) handleMode(w http.ResponseWriter, r *http.Request) {
	expires, ok := s.session(r)
	if !ok {
		http.Redirect(w, r, "/?state=expired", http.StatusSeeOther)
		return
	}
	if !s.csrfOK(r.FormValue("csrf"), expires) {
		s.clearSession(w, r)
		http.Redirect(w, r, "/?state=expired", http.StatusSeeOther)
		return
	}

	name := r.FormValue("mode")
	if !knownMode(name) {
		http.Redirect(w, r, "/?state=no-mode", http.StatusSeeOther)
		return
	}
	if err := writeMode(s.cfg.modeFile, name); err != nil {
		log.Printf("panel: write mode: %v", err)
		http.Redirect(w, r, "/?state=save-failed", http.StatusSeeOther)
		return
	}
	if err := s.restart(); err != nil {
		log.Printf("panel: restart: %v", err)
		http.Redirect(w, r, "/?state=restart-failed", http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, "/?state=restarting", http.StatusSeeOther)
}

// The container's only process is the game server, so quit exits it and the
// restart policy starts it again, reading the mode file on the way up.
func (s *server) restart() error {
	c, err := rconDial(s.cfg.rconAddr, s.cfg.rconPW, rconRestartTimeout)
	if err != nil {
		return err
	}
	defer c.Close()
	return c.send("quit")
}

func (s *server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.session(r); !ok {
		http.Error(w, "Sign in to see the server status.", http.StatusUnauthorized)
		return
	}
	current := readMode(s.cfg.modeFile)
	probe := s.probeRCON()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(struct {
		Online bool   `json:"online"`
		Mode   string `json:"mode"`
		Text   string `json:"text"`
	}{probe == nil, current, statusText(probe, current)})
}
