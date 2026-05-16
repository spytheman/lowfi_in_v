#!/usr/bin/env php
<?php

declare(strict_types=1);

final class Song
{
    /** @var string */
    public $url;

    /** @var string */
    public $title;

    /** @var int */
    public $number;

    public function __construct(string $url, string $title, int $number = 0)
    {
        $this->url = $url;
        $this->title = $title;
        $this->number = $number;
    }

    public function localPath(string $songLocalDir): string
    {
        return $songLocalDir . DIRECTORY_SEPARATOR . fnv1a64_decimal($this->url) . '.mp3';
    }
}

final class App
{
    /** @var list<Song> */
    private array $songs;

    /** @var list<Song> */
    private array $downloaded = [];

    /** @var list<array{song: Song, proc: resource}> */
    private array $jobs = [];

    private int $counter = 0;

    /** @var string */
    private $songLocalDir;

    public function __construct(string $songLocalDir, array $songs)
    {
        $this->songLocalDir = $songLocalDir;
        $this->songs = array_values($songs);
    }

    public function addRandomSong(): void
    {
        if ($this->songs === []) {
            return;
        }

        $index = array_rand($this->songs);
        $song = $this->songs[$index];

        $this->counter++;
        $this->downloadLocalFile($song, $this->counter);
    }

    public function downloadLocalFile(Song $osong, int $counter): void
    {
        $song = new Song($osong->url, $osong->title, $counter);
        $localPath = $song->localPath($this->songLocalDir);

        if (!file_exists($localPath)) {
            $script = self::downloadScript($localPath, $song->url);
            $command = self::shellCommand($script);
            $descriptors = [
                0 => ['file', '/dev/null', 'r'],
                1 => ['file', '/dev/null', 'w'],
                2 => ['file', '/dev/null', 'w'],
            ];
            $pipes = [];
            $proc = @proc_open($command, $descriptors, $pipes);
            if (is_resource($proc)) {
                $this->jobs[] = ['song' => $song, 'proc' => $proc];
                return;
            }

            $status = 0;
            system($command, $status);
        }

        $this->downloaded[] = $song;
    }

    public function removeSong(Song $song): void
    {
        $songPath = $song->localPath($this->songLocalDir);
        @unlink($songPath);
    }

    public function addAnother(Song $song): void
    {
        $this->removeSong($song);
        $this->addRandomSong();
    }

    public function nextDownloadedSong(): Song
    {
        while (true) {
            $this->pumpJobs();

            if ($this->downloaded !== []) {
                /** @var Song $song */
                $song = array_shift($this->downloaded);
                return $song;
            }

            usleep(100000);
        }
    }

    private function pumpJobs(): void
    {
        foreach ($this->jobs as $index => $job) {
            $status = proc_get_status($job['proc']);
            if ($status['running']) {
                continue;
            }

            proc_close($job['proc']);
            unset($this->jobs[$index]);
            $this->downloaded[] = $job['song'];
        }

        $this->jobs = array_values($this->jobs);
    }

    private static function downloadScript(string $localPath, string $url): string
    {
        $quotedPath = escapeshellarg($localPath);
        $quotedUrl = escapeshellarg($url);

        return "for attempt in 1 2 3 4 5; do wget --quiet --output-document={$quotedPath} {$quotedUrl} && exit 0; sleep 0.5; done; exit 1";
    }

    private static function shellCommand(string $script): string
    {
        return '/bin/sh -c ' . escapeshellarg($script);
    }
}

function loadSongs(string $path): array
{
    $lines = file($path, FILE_IGNORE_NEW_LINES);
    if ($lines === false || $lines === []) {
        throw new RuntimeException('Unable to load song list.');
    }

    $baseUrl = array_shift($lines);
    if (!is_string($baseUrl) || $baseUrl === '') {
        throw new RuntimeException('Invalid song list.');
    }

    $songs = [];
    foreach ($lines as $line) {
        $data = explode('!', $baseUrl . $line);
        $songs[] = new Song($data[0], $data[1] ?? '');
    }

    return $songs;
}

function should_be_present(string $cmd): void
{
    $output = [];
    $status = 0;
    exec('command -v ' . escapeshellarg($cmd), $output, $status);

    if ($status !== 0 || $output === []) {
        fwrite(STDERR, "This program needs {$cmd} to work." . PHP_EOL);
        exit(1);
    }
}

function unbuffer_stdout(): void
{
    if (function_exists('stream_set_write_buffer')) {
        stream_set_write_buffer(STDOUT, 0);
    }
}

function fnv1a64_decimal(string $input): string
{
    $hex = hash('fnv1a64', $input);
    if ($hex === false) {
        throw new RuntimeException('fnv1a64 hash is not available.');
    }

    return hex_to_decimal_string($hex);
}

function hex_to_decimal_string(string $hex): string
{
    $decimal = '0';
    $hex = strtolower(trim($hex));

    foreach (str_split($hex) as $char) {
        $digit = hexdec($char);
        $decimal = decimal_mul_small($decimal, 16);
        $decimal = decimal_add_small($decimal, $digit);
    }

    return ltrim($decimal, '0') ?: '0';
}

function decimal_mul_small(string $decimal, int $multiplier): string
{
    if ($decimal === '0' || $multiplier === 0) {
        return '0';
    }

    $carry = 0;
    $result = '';
    for ($i = strlen($decimal) - 1; $i >= 0; $i--) {
        $product = ((int) $decimal[$i]) * $multiplier + $carry;
        $result .= (string) ($product % 10);
        $carry = intdiv($product, 10);
    }

    while ($carry > 0) {
        $result .= (string) ($carry % 10);
        $carry = intdiv($carry, 10);
    }

    return strrev($result);
}

function decimal_add_small(string $decimal, int $addend): string
{
    $carry = $addend;
    $result = '';
    for ($i = strlen($decimal) - 1; $i >= 0; $i--) {
        $sum = ((int) $decimal[$i]) + $carry;
        $result .= (string) ($sum % 10);
        $carry = intdiv($sum, 10);
    }

    while ($carry > 0) {
        $result .= (string) ($carry % 10);
        $carry = intdiv($carry, 10);
    }

    return strrev($result);
}

function main(): void
{
    should_be_present('mpg321');
    should_be_present('wget');
    unbuffer_stdout();

    $songLocalDir = rtrim(sys_get_temp_dir(), DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . 'lowfi';
    @mkdir($songLocalDir, 0777, true);

    echo 'Local folder: ' . $songLocalDir . PHP_EOL;

    $songs = loadSongs(__DIR__ . DIRECTORY_SEPARATOR . 'chillhop.txt');
    $app = new App($songLocalDir, $songs);

    for ($i = 0; $i < 5; $i++) {
        $app->addRandomSong();
    }

    while (true) {
        $song = $app->nextDownloadedSong();
        printf("Playing \"%s\" from URL: %-40s ...\n", $song->title, $song->url);

        $command = 'mpg321 --quiet ' . escapeshellarg($song->localPath($songLocalDir));
        $exitCode = 0;
        exec($command, $unusedOutput, $exitCode);

        if ($exitCode === 4) {
            fwrite(STDERR, "mpv was interrupted by Ctrl-C. Good bye." . PHP_EOL);
            exit(1);
        }

        $app->addAnother($song);
    }
}

main();
