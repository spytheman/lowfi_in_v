require "file_utils"
require "time"

SONG_LOCAL_DIR = File.join(Dir.tempdir, "lowfi")
CHILLHOP_TEXT  = {{ read_file("#{__DIR__}/chillhop.txt") }}

def fnv1a64(text : String) : UInt64
  hash = 0xcbf29ce484222325_u64
  text.each_byte do |byte|
    hash ^= byte.to_u64
    hash &*= 0x100000001b3_u64
  end
  hash
end

def create_songs : Array(Song)
  content = CHILLHOP_TEXT.split('\n').reject(&.empty?)
  baseurl = content[0]
  content[1..].compact_map do |line|
    next if line.empty?
    new_song(baseurl + line)
  end
end

def new_song(line : String) : Song
  data = line.split('!', 2)
  raise ArgumentError.new("Invalid song line: #{line}") if data.size < 2
  Song.new(data[0], data[1])
end

struct Song
  getter url : String
  getter title : String
  getter number : Int32

  def initialize(@url : String, @title : String, @number : Int32 = 0)
  end

  def local_path : String
    File.join(SONG_LOCAL_DIR, "#{fnv1a64(url)}.mp3")
  end
end

SONGS = create_songs

class App
  getter downloaded : Channel(Song)

  def initialize
    @downloaded = Channel(Song).new(5)
    @counter = Atomic(Int32).new(0)
  end

  def add_random_song
    song = SONGS.sample
    counter = @counter.add(1) + 1
    spawn do
      download_local_file(song, counter)
    end
  end

  def download_local_file(osong : Song, counter : Int32)
    song = Song.new(osong.url, osong.title, counter)
    lpath = song.local_path

    unless File.exists?(lpath)
      5.times do
        status = Process.run(
          "wget",
          ["--quiet", "--output-document=#{lpath}", song.url],
          input: Process::Redirect::Inherit,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit,
        )

        if status.exit_code != 0
          sleep 500.milliseconds
          next
        end

        break
      end
    end

    @downloaded.send(song)
  end

  def remove_song(song : Song)
    File.delete(song.local_path)
  rescue
  end

  def add_another(song : Song)
    remove_song(song)
    add_random_song
  end
end

def should_be_present(cmd : String)
  return if Process.find_executable(cmd)

  STDERR.puts "This program needs #{cmd} to work."
  exit 1
end

should_be_present("mpg321")
should_be_present("wget")
STDOUT.sync = true
FileUtils.mkdir_p(SONG_LOCAL_DIR) rescue nil
puts "Local folder: #{SONG_LOCAL_DIR}"

app = App.new
5.times do
  app.add_random_song
end

loop do
  song = app.downloaded.receive
  puts %(Playing "#{song.title}" from URL: #{song.url.ljust(40)} ...)
  result = Process.run(
    "mpg321",
    ["--quiet", song.local_path],
    input: Process::Redirect::Inherit,
    output: Process::Redirect::Inherit,
    error: Process::Redirect::Inherit,
  )
  pp result.exit_code

  if result.exit_code == 4
    STDERR.puts "mpv was interrupted by Ctrl-C. Good bye."
    exit 1
  end

  app.add_another(song)
end
