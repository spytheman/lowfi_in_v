module main

import os
import rand
import time
import hash.fnv1a

const song_local_dir = os.join_path(os.vtmp_dir(), 'lowfi')

const songs = create_songs()

fn create_songs() []Song {
	content := $embed_file('chillhop.txt').to_string().split_into_lines()
	baseurl := content[0]
	song_lines := content#[1..].map(baseurl + it)
	return song_lines.map(new_song(it))
}

fn new_song(line string) Song {
	data := line.split('!')
	return Song{
		url:   data[0]
		title: data[1]
	}
}

struct Song {
	url    string
	title  string
	number int
}

fn (song Song) local_path() string {
	return '${song_local_dir}/${fnv1a.sum64_string(song.url)}.mp3'
}

struct App {
	downloaded chan Song = chan Song{cap: 5}
}

fn (mut app App) add_random_song() {
	song := rand.element(songs) or { return }
	unsafe {
		mut static scounter := 0
		scounter++
		spawn app.download_local_file(song, scounter)
	}
}

fn (mut app App) download_local_file(osong Song, counter int) {
	song := Song{
		...osong
		number: counter
	}
	lpath := song.local_path()
	if !os.exists(lpath) {
		for _ in 0 .. 5 {
			if os.system('wget --quiet --output-document=${lpath} ${song.url}') != 0 {
				time.sleep(500 * time.millisecond)
				continue
			}
			break
		}
	}
	app.downloaded <- song
}

fn (mut app App) remove_song(song Song) {
	song_path := song.local_path()
	os.rm(song_path) or {}
}

fn (mut app App) add_another(song Song) {
	app.remove_song(song)
	app.add_random_song()
}

fn should_be_present(cmd string) {
	os.find_abs_path_of_executable(cmd) or {
		eprintln('This program needs ${cmd} to work.')
		exit(1)
	}
}

fn main() {
	should_be_present('mpg321')
	should_be_present('wget')
	unbuffer_stdout()
	os.mkdir_all(song_local_dir) or {}
	println('Local folder: ${song_local_dir}')
	mut app := App{}
	for _ in 0 .. 5 {
		app.add_random_song()
	}
	for {
		song := <-app.downloaded
		println('Playing "${song.title}" from URL: ${song.url:-40s} ...')
		//		res := os.system('mpv --no-audio-display ${song.local_path()}')
		res := os.system('mpg321 --quiet ${song.local_path()}')
		dump(res)
		if res == 4 {
			eprintln('mpv was interrupted by Ctrl-C. Good bye.')
			exit(1)
		}
		app.add_another(song)
	}
}
