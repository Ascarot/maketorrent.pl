#!/usr/bin/perl

use warnings;
use strict;
use File::Find qw(finddepth);
use Digest::SHA1 qw(sha1);

my $output;
my @trackers;
my $private = 0;
my $piece_size;
my $name;
my $comment;
my $createdby;
my $dir;
my $debug = 0;

# sanity limit
my $piece_size_min = 16;
my $piece_size_max = 26;

sub usage {
	my $str = '
Usage: maketorrent.pl [OPTIONS] <target>
Options:
-a http://example.com/		add tracker URL
				you can use this option more than once
-c mycomment			add comment
-l N				set piece size to 2^N
				default is from 18 to 24,
				based on data size
-n name				torrent name, default is target basename
-o data.torrent			output file, default is as in name
-p				set private flag
';
	print STDERR $str;
}

while (my $arg = shift @ARGV) {
	if ($arg eq '-h' or $arg eq '--help') {
		usage;
		exit 0;
	} elsif ($arg eq '-a') {
		my $tracker = shift @ARGV;
		unless ($tracker) {
			print STDERR "Option -a requires tracker URL!\n";
			usage;
			exit 1;
		} elsif (not $tracker =~ /^(udp|http|https):\/\//i) {
			print STDERR "$tracker is not a tracker URL!\n";
			usage;
			exit 1;
		}
		push @trackers, $tracker;
	} elsif ($arg eq '-c') {
		$comment = shift @ARGV;
		unless ($comment) {
			print STDERR "Option -c requires comment!\n";
			usage;
			exit 1;
		}
	} elsif ($arg eq '-l') {
		$piece_size = shift @ARGV;
		unless ($piece_size and $piece_size =~ /^[0-9]+$/) {
			print STDERR "Option -l requires integer value!\n";
			usage;
			exit 1;
		}
		if ($piece_size < $piece_size_min or $piece_size > $piece_size_max) {
			print STDERR "Piece size must be between 16 and 26 (64KB and 64MB respectively)!\n";
			exit 1;
		}
	} elsif ($arg eq '-n') {
		$name = shift @ARGV;
		unless ($name) {
			print STDERR "Option -n requires torrent name!\n";
			usage;
			exit 1;
		}
	} elsif ($arg eq '-o') {
		$output = shift @ARGV;
		unless ($output) {
			print STDERR "Option -o requires filename!\n";
			usage;
			exit 1;
		}
	} elsif ($arg eq '-p') {
		$private = 1;
	} elsif (not $dir) {
		$dir = $arg;
	} else {
		print STDERR "Unknown option $arg!\n";
		usage;
		exit 1;
	}
}

if (not $dir) {
	print STDERR "Source isn't selected!\n";
	usage;
	exit 1;
} elsif (not -e $dir) {
	print STDERR "Source isn't found!\n";
	usage;
	exit 1;
} elsif (not -d $dir and not -f $dir) {
	print STDERR "You can only select a file or a directory!\n";
	usage;
	exit 1;
}

if (scalar @trackers == 0) {
	print STDERR "You must add at least one tracker!\n";
	usage;
	exit 1;
}

print "Beware, symlinks are not supported yet!\n";

sub dlog {
	return unless ($debug);
	my ($line) = @_;
	print $line;
}

sub bencode {
	my ($arg) = @_;
	my $str .= length($arg) . ":" . "$arg";
	return $str;
}

my $tdata = "d";

$tdata .= bencode("announce");
$tdata .= bencode($trackers[0]);
if (scalar @trackers > 1) {
	$tdata .= bencode("announce-list");
	$tdata .= "l";
	for my $tracker (@trackers) {
		$tdata .= "l" . bencode($tracker) . "e";
	}
	$tdata .= "e";
}

if ($comment) {
	$tdata .= bencode("comment") . bencode($comment);
}

if ($createdby) {
	$tdata .= bencode("created by") . bencode($createdby);
}

my $time = time;
$tdata .= bencode("creation date") . "i" . $time . "e";

my @files;
sub wanted {
	return unless (-f $_);
	push @files, $File::Find::name;
}
finddepth(\&wanted, $dir);
my @files_sorted = sort @files;

my $size_total = 0;
for my $file (@files_sorted) {
	my @info = stat($file);
	my $size = $info[7];
	$size_total += $size;
}

unless ($piece_size) {
	# Calculating automatic piece size if not defined
	my $power = 18;
	while ($power < 24 and 2 ** $power < $size_total / 2048) {
		$power++;
	}
	$piece_size = 2 ** $power;
} else {
	$piece_size = 2 ** $piece_size;
}

my $pieces_total = int($size_total / $piece_size) + 1;

my $dir_s = $dir;
$dir_s .= "/" unless ($dir =~ /\/$/);

$tdata .= bencode("info") . "d";
if (-f $dir) {
	$tdata .= bencode("length") . "i" . $size_total . "e";
} elsif (-d $dir) {
	$tdata .= bencode("files") . "l";
	for my $file (@files_sorted) {
		$tdata .= "d" . bencode("length");
		my @info = stat($file);
		$tdata .= "i" . $info[7] . "e" . bencode("path") . "l";
		my $basename = substr($file, length($dir_s));
		my @arr = split /\//, $basename;
		for my $token (@arr) {
			$tdata .= bencode($token);
		}
		# list and dictionary end
		$tdata .= "ee";
	}
	$tdata .= "e";
} else {
	print STDERR "Something went wrong!\n";
	exit 1;
}

unless ($name) {
	$name = $dir;
	$name =~ s/\/+$//;
	$name =~ s/^.*\///; # greedy regex
}
$tdata .= bencode("name") . bencode($name);

$tdata .= bencode("piece length") . "i" . $piece_size . "e";

# disabling output buffering
$| = 1;

my $bdata = "";
my $buffer = "";
my $pieces_done = 0;
for my $file (@files_sorted) {
	my $to_read = $piece_size - length($buffer);
	open my $fh, "<", $file or die "Unable to open $file!";
	my $data;
	read $fh, $data, $to_read;
	$buffer .= $data;
	unless (length($buffer) < $piece_size) {
		$bdata .= sha1($buffer);
		$pieces_done++;
		$buffer = "";
		while (read $fh, $data, $piece_size) {
			unless (length($data) < $piece_size) {
				$bdata .= sha1($data);
				$pieces_done++;
				print "\r$pieces_done / $pieces_total";
			} else {
				$buffer = $data;
			}
		}
	}
	close $fh;
	my @info = stat($file);
}
if (length($buffer) > 0) {
	$bdata .= sha1($buffer);
	$pieces_done++;
	print "\r$pieces_done / $pieces_total";
}
print "\n";
$tdata .= bencode("pieces") . bencode($bdata);

if ($private) {
	$tdata .= bencode("private") . "i1e";
}

$tdata .= "ee"; # end of info and file

$output = $name . ".torrent" unless ($output);

open my $fh, ">", $output;
print $fh $tdata;
close $fh;
