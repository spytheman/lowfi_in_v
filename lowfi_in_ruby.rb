#!/usr/bin/env ruby

require "fileutils"
require "thread"
require "tmpdir"

FNV64_OFFSET_BASIS = 0xcbf29ce484222325
FNV64_PRIME = 0x100000001b3
FNV64_MASK = 0xffff_ffff_ffff_ffff

def fnv1a_64_string(str)
  hash = FNV64_OFFSET_BASIS
  str.encode(Encoding::UTF_8).bytes.each do |byte|
    hash ^= byte
    hash = (hash * FNV64_PRIME) & FNV64_MASK
  end
  hash
end

class Song
  attr_reader :url, :title, :number

  def initialize(url:, title:, number: 0)
    @url = url
    @title = title
    @number = number
  end

  def local_path
    File.join(self.class.local_dir, "#{fnv1a_64_string(url)}.mp3")
  end

  def self.local_dir
    @local_dir ||= File.join(Dir.tmpdir, "lowfi")
  end
end

def new_song(line)
  url, title = line.split("!", 2)
  Song.new(url: url, title: title)
end

def create_songs
  content = File.read(File.join(__dir__, "chillhop.txt")).lines(chomp: true)
  baseurl = content.first
  content.drop(1).map { |line| new_song(baseurl + line) }
end

SONGS = create_songs.freeze

class App
  attr_reader :downloaded

  def initialize
    @downloaded = SizedQueue.new(5)
    @counter = 0
    @counter_mutex = Mutex.new
  end

  def add_random_song
    song = SONGS.sample
    return unless song

    counter = nil
    @counter_mutex.synchronize do
      @counter += 1
      counter = @counter
    end

    Thread.new(song, counter) do |selected_song, selected_counter|
      download_local_file(selected_song, selected_counter)
    end
  end

  def download_local_file(osong, counter)
    song = Song.new(url: osong.url, title: osong.title, number: counter)
    lpath = song.local_path

    unless File.exist?(lpath)
      5.times do
        unless system("wget", "--quiet", "--output-document=#{lpath}", song.url)
          sleep 0.5
          next
        end
        break
      end
    end

    @downloaded << song
  end

  def remove_song(song)
    File.delete(song.local_path)
  rescue StandardError
    nil
  end

  def add_another(song)
    remove_song(song)
    add_random_song
  end
end

def executable_present?(cmd)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
    path = File.join(dir, cmd)
    File.file?(path) && File.executable?(path)
  end
end

def should_be_present(cmd)
  return if executable_present?(cmd)

  warn "This program needs #{cmd} to work."
  exit(1)
end

if __FILE__ == $0
  Thread.abort_on_exception = true

  should_be_present("mpg321")
  should_be_present("wget")

  STDOUT.sync = true
  FileUtils.mkdir_p(Song.local_dir)
  puts "Local folder: #{Song.local_dir}"

  app = App.new
  5.times { app.add_random_song }

  loop do
    song = app.downloaded.pop
    puts "Playing \"#{song.title}\" from URL: #{format('%-40s', song.url)} ..."
    system("mpg321", "--quiet", song.local_path)
    res = $?.exitstatus || 0
    warn "res = #{res}"

    if res == 4
      warn "mpg321 was interrupted by Ctrl-C. Good bye."
      exit(1)
    end

    app.add_another(song)
  end
end
