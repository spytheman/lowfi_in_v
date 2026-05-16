const std = @import("std");

const Song = struct {
    url: []const u8,
    title: []const u8,
    number: u32 = 0,

    fn localPath(self: Song, allocator: std.mem.Allocator) ![]u8 {
        const hash = std.hash.Fnv1a_64.hash(self.url);
        return std.fmt.allocPrint(allocator, "{s}/{d}.mp3", .{ song_local_dir, hash });
    }
};

const SongQueue = struct {
    items: []Song,
    cap: usize,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    not_full: std.Thread.Condition = .{},

    fn init(allocator: std.mem.Allocator, cap: usize) !SongQueue {
        return .{
            .items = try allocator.alloc(Song, cap),
            .cap = cap,
        };
    }

    fn push(self: *SongQueue, song: Song) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count == self.cap) {
            self.not_full.wait(&self.mutex);
        }

        self.items[self.tail] = song;
        self.tail = (self.tail + 1) % self.cap;
        self.count += 1;
        self.not_empty.signal();
    }

    fn pop(self: *SongQueue) Song {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count == 0) {
            self.not_empty.wait(&self.mutex);
        }

        const song = self.items[self.head];
        self.head = (self.head + 1) % self.cap;
        self.count -= 1;
        self.not_full.signal();
        return song;
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    downloaded: SongQueue,

    fn init(allocator: std.mem.Allocator) !App {
        return .{
            .allocator = allocator,
            .downloaded = try SongQueue.init(allocator, 5),
        };
    }
};

var song_local_dir: []const u8 = "";
var songs: []Song = &[_]Song{};
var song_counter: u32 = 0;

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r");
}

fn buildSongLocalDir(allocator: std.mem.Allocator) ![]u8 {
    const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
    return std.fs.path.join(allocator, &[_][]const u8{ tmp, "lowfi" });
}

fn parseSongLine(allocator: std.mem.Allocator, baseurl: []const u8, line: []const u8) !Song {
    if (std.mem.indexOfScalar(u8, line, '!')) |bang| {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ baseurl, line[0..bang] });
        const title = try allocator.dupe(u8, line[bang + 1 ..]);
        return .{ .url = url, .title = title };
    }

    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ baseurl, line });
    const title = try allocator.dupe(u8, "");
    return .{ .url = url, .title = title };
}

fn createSongs(allocator: std.mem.Allocator) ![]Song {
    const embedded = @embedFile("chillhop.txt");
    var lines = std.mem.splitScalar(u8, embedded, '\n');

    const baseurl_raw = lines.next() orelse return error.InvalidFormat;
    const baseurl = trimLine(baseurl_raw);

    var list = std.ArrayList(Song).init(allocator);
    errdefer list.deinit();

    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0) continue;

        try list.append(try parseSongLine(allocator, baseurl, line));
    }

    return try list.toOwnedSlice();
}

fn hasExecutable(allocator: std.mem.Allocator, cmd: []const u8) !bool {
    const path = std.posix.getenv("PATH") orelse return false;
    var parts = std.mem.splitScalar(u8, path, ':');

    while (parts.next()) |raw_dir| {
        const dir = if (raw_dir.len == 0) "." else raw_dir;
        const candidate = try std.fs.path.join(allocator, &[_][]const u8{ dir, cmd });
        defer allocator.free(candidate);

        if (std.posix.access(candidate, std.posix.X_OK)) |_| {
            return true;
        } else |_| {}
    }

    return false;
}

fn shouldBePresent(allocator: std.mem.Allocator, cmd: []const u8) !void {
    if (!try hasExecutable(allocator, cmd)) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("This program needs {s} to work.\n", .{cmd});
        std.process.exit(1);
    }
}

fn commandStatusToInt(term: std.process.Child.Term) i32 {
    return switch (term) {
        .Exited => |code| @as(i32, code),
        .Signal => |sig| 128 + @as(i32, @intCast(sig)),
        .Stopped => |sig| 128 + @as(i32, @intCast(sig)),
        .Unknown => |code| @as(i32, @intCast(code)),
    };
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) i32 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = child.spawnAndWait() catch return 127;
    return commandStatusToInt(term);
}

fn downloadLocalFile(app: *App, osong: Song, counter: u32) void {
    const song = Song{
        .url = osong.url,
        .title = osong.title,
        .number = counter,
    };

    const lpath = song.localPath(app.allocator) catch {
        std.process.exit(1);
    };
    defer app.allocator.free(lpath);

    var exists = true;
    if (std.fs.accessAbsolute(lpath, .{})) |_| {} else |_| {
        exists = false;
    }
    if (!exists) {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const argv = [_][]const u8{
                "wget",
                "--quiet",
                "--output-document",
                lpath,
                song.url,
            };
            if (runCommand(app.allocator, argv[0..]) != 0) {
                std.time.sleep(500 * std.time.ns_per_ms);
                continue;
            }
            break;
        }
    }

    app.downloaded.push(song);
}

fn downloadLocalFileThread(app: *App, osong: Song, counter: u32) void {
    downloadLocalFile(app, osong, counter);
}

fn pickRandomSong() ?Song {
    if (songs.len == 0) return null;
    const idx = std.crypto.random.intRangeLessThan(usize, 0, songs.len);
    return songs[idx];
}

fn addRandomSong(app: *App) void {
    const song = pickRandomSong() orelse return;
    song_counter += 1;
    const counter = song_counter;

    const spawn_result = std.Thread.spawn(.{}, downloadLocalFileThread, .{ app, song, counter });
    if (spawn_result) |thread| {
        thread.detach();
    } else |_| {
        downloadLocalFile(app, song, counter);
    }
}

fn removeSong(app: *App, song: Song) void {
    const song_path = song.localPath(app.allocator) catch return;
    defer app.allocator.free(song_path);
    std.fs.deleteFileAbsolute(song_path) catch {};
}

fn addAnother(app: *App, song: Song) void {
    removeSong(app, song);
    addRandomSong(app);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    try shouldBePresent(allocator, "mpg321");
    try shouldBePresent(allocator, "wget");

    song_local_dir = try buildSongLocalDir(allocator);
    std.fs.cwd().makePath(song_local_dir) catch {};

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Local folder: {s}\n", .{song_local_dir});

    songs = try createSongs(allocator);

    var app = try App.init(allocator);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        addRandomSong(&app);
    }

    while (true) {
        const song = app.downloaded.pop();
        try stdout.print("Playing \"{s}\" from URL: {s:<40} ...\n", .{ song.title, song.url });

        const lpath = try song.localPath(allocator);
        defer allocator.free(lpath);

        const argv = [_][]const u8{
            "mpg321",
            "--quiet",
            lpath,
        };
        const res = runCommand(allocator, argv[0..]);
        std.debug.print("res: {d}\n", .{res});

        if (res == 4) {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("mpv was interrupted by Ctrl-C. Good bye.\n", .{});
            std.process.exit(1);
        }

        addAnother(&app, song);
    }
}
