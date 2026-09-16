package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
)

type mode struct {
	Name  string
	Label string
	Desc  string
}

var modes = []mode{
	{"matchzy", "MatchZy", "MatchZy for practice and pugs, with ChatControl."},
	{"retakes", "Retakes", "cs2-retakes with instadefuse and RetakesAllocator, with ChatControl."},
	{"chatcontrol", "ChatControl", "ChatControl alone, on the stock competitive game."},
}

func modeLabel(name string) string {
	for _, m := range modes {
		if m.Name == name {
			return m.Label
		}
	}
	return "Mode unknown"
}

func knownMode(name string) bool {
	for _, m := range modes {
		if m.Name == name {
			return true
		}
	}
	return false
}

// An absent or hand-edited file is a state the page reports, not an error: the
// boot hook would treat anything it does not recognise the same way.
func readMode(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 256))
	if err != nil {
		return ""
	}
	name := strings.TrimSpace(string(b))
	if !knownMode(name) {
		return ""
	}
	return name
}

func writeMode(path, name string) error {
	dir := filepath.Dir(path)
	f, err := os.CreateTemp(dir, ".mode-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)

	write := func() error {
		if _, err := f.WriteString(name + "\n"); err != nil {
			return err
		}
		// The game server container reads this file as a different uid than the
		// panel, and CreateTemp makes it 0600.
		if err := f.Chmod(0o644); err != nil {
			return err
		}
		return f.Sync()
	}
	if err := write(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}

	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
