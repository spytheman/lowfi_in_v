#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile tmpdir);
use IO::Select;
use Math::BigInt;
use POSIX ();

my $SONG_LOCAL_DIR = catdir( tmpdir(), 'lowfi' );
my $DOWNLOAD_COUNTER = 0;

$| = 1;

my $songs = create_songs();
my @active_downloads;
my %active_by_fd;
my @ready_songs;

sub create_songs {
    open my $fh, '<', 'chillhop.txt' or die "open chillhop.txt: $!";
    my @lines = <$fh>;
    close $fh;

    chomp @lines;
    s/\r\z// for @lines;

    my $baseurl = shift @lines;
    my @songs;
    for my $line (@lines) {
        next if $line eq '';
        push @songs, new_song( $baseurl . $line );
    }
    return \@songs;
}

sub new_song {
    my ($line) = @_;
    my ( $url, $title ) = split /!/, $line, 2;
    return {
        url   => $url,
        title => $title,
    };
}

sub fnv1a_sum64_string {
    my ($text) = @_;

    my $hash  = Math::BigInt->new('14695981039346656037');
    my $prime = Math::BigInt->new('1099511628211');
    my $mod   = Math::BigInt->new('18446744073709551616');

    foreach my $byte ( unpack 'C*', $text ) {
        $hash->bxor($byte);
        $hash->bmul($prime);
        $hash->bmod($mod);
    }

    return $hash->bstr;
}

sub local_path {
    my ($song) = @_;
    return catfile( $SONG_LOCAL_DIR, fnv1a_sum64_string( $song->{url} ) . '.mp3' );
}

sub rand_song {
    return undef if !@$songs;
    return $songs->[ int( rand(@$songs) ) ];
}

sub should_be_present {
    my ($cmd) = @_;
    for my $dir ( split /:/, ( $ENV{PATH} // '' ) ) {
        next if $dir eq '';
        my $path = catfile( $dir, $cmd );
        return if -f $path && -x _;
    }
    print STDERR "This program needs $cmd to work.\n";
    exit 1;
}

sub play_exit_code {
    my (@cmd) = @_;
    my $status = system @cmd;
    return 127 if $status == -1;
    return 128 + ( $status & 127 ) if $status & 127;
    return $status >> 8;
}

sub sleep_ms {
    my ($ms) = @_;
    select undef, undef, undef, $ms / 1000;
}

sub download_local_file {
    my ( $osong, $counter ) = @_;
    my %song = ( %{$osong}, number => $counter );
    my $lpath = local_path(\%song);

    if ( !-e $lpath ) {
        for ( 1 .. 5 ) {
            my $res = system( 'wget', '--quiet', "--output-document=$lpath", $song{url} );
            if ( $res == 0 ) {
                last;
            }
            sleep_ms(500);
        }
    }

    return \%song;
}

sub spawn_download {
    my ($song) = @_;

    my $counter = ++$DOWNLOAD_COUNTER;
    pipe( my $reader, my $writer ) or die "pipe: $!";
    my $pid = fork();
    die "fork: $!" if !defined $pid;

    if ( $pid == 0 ) {
        close $reader;
        my $downloaded = download_local_file( $song, $counter );
        print {$writer} join( "\t", @{$downloaded}{qw(url title number)} ), "\n";
        close $writer;
        POSIX::_exit(0);
    }

    close $writer;
    my $fd = fileno($reader);
    my $entry = {
        pid  => $pid,
        fh   => $reader,
        fd   => $fd,
        song => $song,
    };
    $active_by_fd{$fd} = $entry;
    push @active_downloads, $entry;
    return $entry;
}

sub collect_completed_downloads {
    return if !@active_downloads;

    my $select = IO::Select->new( map { $_->{fh} } @active_downloads );
    my @ready_fhs = $select->can_read();

    for my $fh (@ready_fhs) {
        my $fd = fileno($fh);
        my $entry = delete $active_by_fd{$fd} or next;

        my $line = <$fh>;
        close $fh;
        waitpid( $entry->{pid}, 0 );

        next if !defined $line;
        chomp $line;
        my ( $url, $title, $number ) = split /\t/, $line, 3;
        push @ready_songs, {
            url    => $url,
            title  => $title,
            number => 0 + $number,
        };
    }

    @active_downloads = grep { exists $active_by_fd{ $_->{fd} } } @active_downloads;
}

sub next_ready_song {
    while ( !@ready_songs ) {
        if ( !@active_downloads ) {
            spawn_download( rand_song() );
            next;
        }
        collect_completed_downloads();
    }
    return shift @ready_songs;
}

sub remove_song {
    my ($song) = @_;
    my $song_path = local_path($song);
    unlink $song_path;
    return;
}

sub add_another {
    my ($song) = @_;
    remove_song($song);
    spawn_download( rand_song() );
}

sub main {
    should_be_present('mpg321');
    should_be_present('wget');

    make_path($SONG_LOCAL_DIR);
    print "Local folder: $SONG_LOCAL_DIR\n";

    for ( 1 .. 5 ) {
        spawn_download( rand_song() );
    }

    while (1) {
        my $song = next_ready_song();
        printf "Playing \"%s\" from URL: %-40s ...\n", $song->{title}, $song->{url};
        my $res = play_exit_code( 'mpg321', '--quiet', local_path($song) );
        warn "res = $res\n";
        if ( $res == 4 ) {
            print STDERR "mpv was interrupted by Ctrl-C. Good bye.\n";
            exit 1;
        }
        add_another($song);
    }
}

main();
