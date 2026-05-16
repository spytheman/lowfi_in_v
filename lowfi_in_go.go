package main

import (
	_ "embed"
	"errors"
	"fmt"
	"hash/fnv"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

//go:embed chillhop.txt
var chillhopFile string

var songLocalDir = filepath.Join(os.TempDir(), "lowfi")

var songs = createSongs()

var songCounter int

type Song struct {
	URL    string
	Title  string
	Number int
}

func (song Song) localPath() string {
	h := fnv.New64a()
	_, _ = h.Write([]byte(song.URL))
	return filepath.Join(songLocalDir, fmt.Sprintf("%d.mp3", h.Sum64()))
}

type App struct {
	downloaded chan Song
}

func createSongs() []Song {
	content := strings.Split(strings.TrimRight(strings.ReplaceAll(chillhopFile, "\r\n", "\n"), "\n"), "\n")
	if len(content) == 0 {
		return nil
	}

	baseURL := content[0]
	songs := make([]Song, 0, len(content)-1)
	for _, line := range content[1:] {
		if strings.TrimSpace(line) == "" {
			continue
		}
		songs = append(songs, newSong(baseURL+line))
	}
	return songs
}

func newSong(line string) Song {
	parts := strings.SplitN(line, "!", 2)
	if len(parts) < 2 {
		return Song{URL: line}
	}
	return Song{
		URL:   parts[0],
		Title: parts[1],
	}
}

func (app *App) addRandomSong() {
	if len(songs) == 0 {
		return
	}
	song := songs[rand.Intn(len(songs))]
	songCounter++
	go app.downloadLocalFile(song, songCounter)
}

func (app *App) downloadLocalFile(osong Song, counter int) {
	song := Song{
		URL:    osong.URL,
		Title:  osong.Title,
		Number: counter,
	}
	lpath := song.localPath()
	if _, err := os.Stat(lpath); err != nil {
		for i := 0; i < 5; i++ {
			cmd := exec.Command("wget", "--quiet", "--output-document="+lpath, song.URL)
			if err := cmd.Run(); err != nil {
				time.Sleep(500 * time.Millisecond)
				continue
			}
			break
		}
	}
	app.downloaded <- song
}

func (app *App) removeSong(song Song) {
	_ = os.Remove(song.localPath())
}

func (app *App) addAnother(song Song) {
	app.removeSong(song)
	app.addRandomSong()
}

func shouldBePresent(cmd string) {
	if _, err := exec.LookPath(cmd); err != nil {
		fmt.Fprintf(os.Stderr, "This program needs %s to work.\n", cmd)
		os.Exit(1)
	}
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return 1
}

func main() {
	rand.Seed(time.Now().UnixNano())
	shouldBePresent("mpg321")
	shouldBePresent("wget")
	if err := os.MkdirAll(songLocalDir, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create local folder: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Local folder: %s\n", songLocalDir)
	app := App{
		downloaded: make(chan Song, 5),
	}
	for i := 0; i < 5; i++ {
		app.addRandomSong()
	}
	for {
		song := <-app.downloaded
		fmt.Printf("Playing %q from URL: %-40s ...\n", song.Title, song.URL)
		cmd := exec.Command("mpg321", "--quiet", song.localPath())
		err := cmd.Run()
		res := exitCode(err)
		fmt.Printf("res: %d\n", res)
		if res == 4 {
			fmt.Fprintln(os.Stderr, "mpv was interrupted by Ctrl-C. Good bye.")
			os.Exit(1)
		}
		app.addAnother(song)
	}
}
