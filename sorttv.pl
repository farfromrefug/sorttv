#!/usr/bin/perl

# 2010 Z. Cliffe Schreuders
# free software: GPL v3 or later
# 
# sorts tv shows into tvshow/series directories
# if the dirs don't exist they are created
# updates xbmc via the web interface
# unsorted files are moved to a dir if specifed
#
# other contributers:
# salithus - xbmc forum


use File::Copy::Recursive "dirmove";
use File::Copy;
use File::Glob ':glob';
use LWP::Simple;
use warnings;
use strict;

my ($sortdir, $tvdir, $nonepisodedir, $xbmcwebserver, $matchtype);
my ($showname, $series, $episode, $pureshowname) = "";
my ($newshows, $new);
my $REDO_FILE = my $moveseasons = "TRUE";
my $usedots = my $rename = my $logfile = 0;

print "SortTV\n", "~" x 6,"\n";
get_config_from_file("sorttv.config");
process_args(@ARGV);
if(!defined($sortdir) || !defined($tvdir)) {
	warn "Incorrect usage or configuration (missing sort or sort-to directories)\n";
	showhelp();
	exit;
}

display_info();

FILE: foreach my $file (bsd_glob($sortdir.'*')) {
	$showname = "";
	# Regex for tv show season directory
	if(-d $file && $file =~ /.*\/(.*)(?:Season|Series)\D0*(\d+).*/i && $1) {
		$pureshowname = $1;
		$showname = fixtitle($pureshowname);
		$series = $2;
		if(move_series($pureshowname, $showname, $series, $file) eq $REDO_FILE) {
			redo FILE;
		}
	# Regex for tv show episode: S01E01 or 1x1 or 1 x 1 etc
	} elsif($file =~ /.*\/(.*)(?:\.|\s)[Ss]0*(\d+)\s*[Ee]0*(\d+).*/
	|| $file =~ /.*\/(.*)(?:\.|\s)0*(\d+)\s*[xX]\s*0*(\d+).*/
	  || ($matchtype eq "--liberal" && $file =~ /.*\/(.*)(?:\.|\s)0*(\d+)\D*0*(\d+).*/)) {
		$pureshowname = $1;
		$showname = fixtitle($pureshowname);
		$series = $2;
		$episode = $3;
		if($showname ne "") {
			if(move_episode($pureshowname, $showname, $series, $episode, $file) eq $REDO_FILE) {
				redo FILE;
			}
		}
	} elsif(defined $nonepisodedir) {
		print "moving non-episode $file to $nonepisodedir\n";
		if(-d $file) {
			dirmove($file, $nonepisodedir . filename($file)) or warn "File $file cannot be copied to $nonepisodedir. : $!";
		} else {
			move($file, $nonepisodedir . filename($file)) or warn "File $file cannot be copied to $nonepisodedir. : $!";
		}
	}
}

if($xbmcwebserver && $newshows) {
	sleep(4);
        get "http://$xbmcwebserver/xbmcCmds/xbmcHttp?command=ExecBuiltIn(Notification(,NEW EPISODES NOW AVAILABLE TO WATCH\n$newshows, 7000))";
}

exit;

sub process_args {
	foreach my $arg (@_) {
		if($arg =~ /^--non-episode-dir:(.*)/ || $arg =~ /^-ne:(.*)/) {
			$nonepisodedir = $1;
			# append a trailing / if it's not there
			$nonepisodedir .= '/' if($nonepisodedir !~ /\/$/);
		} elsif($arg =~ /^--xbmc-web-server:(.*)/ || $arg =~ /^-xs:(.*)/) {
			$xbmcwebserver = $1;
		} elsif($arg =~ /^--match-type:(.*)/ || $arg =~ /^-mt:(.*)/) {
			$matchtype = $1;
		} elsif($arg =~ /^--log-file:(.*)/ || $arg =~ /^-o:(.*)/) {
			$logfile = $1;
		} elsif($arg =~ /^--read-config-file:(.*)/ || $arg =~ /^-conf:(.*)/) {
			get_config_from_file($1);
		} elsif($arg =~ /^--directory-to-sort:(.*)/ || $arg =~ /^-sort:(.*)/) {
			$sortdir = $1;
			# append a trailing / if it's not there
			$sortdir .= '/' if($sortdir !~ /\/$/);
		} elsif($arg =~ /^--directory-to-sort-into:(.*)/ || $arg =~ /^-sortto:(.*)/) {
			$tvdir = $1;
			# append a trailing / if it's not there
			$tvdir .= '/' if($tvdir !~ /\/$/);
		} elsif($arg eq "--help" || $arg eq "-h") {
			showhelp();
		} elsif(!defined($sortdir)) {
			$sortdir = $arg;
			# append a trailing / if it's not there
			$sortdir .= '/' if($sortdir !~ /\/$/);
		} elsif(!defined($tvdir)) {
			$tvdir = $arg;
			# append a trailing / if it's not there
			$tvdir .= '/' if($tvdir !~ /\/$/);
		} else {
			warn "Incorrect usage (invalid option): $arg\n";
			showhelp();
		}
	}
}

sub get_config_from_file {
	my ($filename) = @_;
	my @arraytoconvert;
	
	if(open (IN, $filename)) {
		print "Reading configuration settings from '$filename'\n";
		while(my $in = <IN>) {
			chomp($in);
			if($in =~ /^\s*#/ || $in =~ /^\s*$/) {
				# ignores comments and whitespace
			} elsif($in =~ /(.+):(.+)/) {
				process_args("--$1:$2");
			} else {
				warn "WARNING: this line does not match expected format: '$in'\n";
			}
		}
		close (IN);
	} else {
		warn "Couldn't open '$filename': $!\n";
	}
}

sub showhelp {
	print "Usage: sorttv [OPTIONS] directory-to-sort directory-to-sort-into\n";
}

sub displayandupdateinfo {
	my ($show, $xbmcwebserver) = @_;

	# update xbmc video library
	get "http://$xbmcwebserver/xbmcCmds/xbmcHttp?command=ExecBuiltIn(updatelibrary(video))";

	# save images etc with media
	# exportlibrary(music|video,true,thumbs,overwrite,actorthumbs)
	get "http://$xbmcwebserver/xbmcCmds/xbmcHttp?command=ExecBuiltIn(exportlibrary(video,true,true,false,true))";

	# pop up a notification on xbmc
	# xbmc.executebuiltin('XBMC.Notification(New content found, ' + filename + ', 2000)')
	get "http://$xbmcwebserver/xbmcCmds/xbmcHttp?command=ExecBuiltIn(Notification(NEW EPISODE, $show, 7000))";
}

# replaces ".", "_" and removes "the" and ","
# removes the dir path
sub fixtitle {
	my ($title) = @_;
	$title = remdot($title);

# 	$title =~ s/\./ /ig;
# 	$title =~ s/_/ /ig;
	$title =~ s/,|the//ig;
	$title =~ s/(.*\/)(.*)/$2/;
	return $title;
}

# removes numbers and spaces
sub fixtitle2 {
	my ($title) = @_;
	$title = fixtitle($title);
	$title =~ s/\d|\s|\(|\)//ig;
	return $title;
}

# removes dots and underscores for creating dirs
sub remdot {
	my ($title) = @_;
	$title =~ s/\./ /ig;
	$title =~ s/_/ /ig;
	$title =~ s/-//ig;
	$title =~ s/'//ig;
	# don't end on whitespace
	$title =~ s/\s$//ig;
	return $title;
}

# removes path
sub filename {
	my ($title) = @_;
	$title =~ s/(.*\/)(.*)/$2/;
	return $title;
}

sub display_info {
	my ($second, $minute, $hour, $dayofmonth, $month, $yearoffset) = localtime();
	my $year = 1900 + $yearoffset;
	my $thetime = "$hour:$minute:$second, $dayofmonth-$month-$year";
	print "\n\n$thetime\n"; 
	print "Sorting $sortdir into $tvdir\n"; 
}

sub move_episode {
	my ($pureshowname, $showname, $series, $episode, $file) = @_;

	print "trying to move $pureshowname season $series episode $episode\n";
	SHOW: foreach my $show (bsd_glob($tvdir.'*')) {
		my $simpleshowname = '^'.fixtitle2($showname).'$';
		if(fixtitle($show) =~ /$showname/i || fixtitle2($show) =~ /$simpleshowname/i) {
			print "found a matching show:\n\t$show\n";
			my $s = $show.'/*';
			my @g=bsd_glob($show);
			foreach my $season (bsd_glob($show.'/*')) {
				if(-d $season.'/' && $season =~ /(?:Season|Series)?\s?0*(\d+)$/i && $1 == $series) {
					print "found a matching season:\n\t$season\n";
					print "moving $file to ", $season . '/' . filename($file), "\n";
					if(-d $file) {
						dirmove($file, $season . '/' . filename($file)) or warn "File $show cannot be copied to $season. : $!";
					} else {
						move($file, $season) or warn "File $show cannot be copied to $season. : $!";
					}
					if($xbmcwebserver) {
						$new = "$showname season $series episode $episode";
						displayandupdateinfo($new, $xbmcwebserver);
						$newshows .= "$new\n";
					}
					# next FILE;
					return 0;
				}
			}
			# didn't find a matching season, make DIR
			print "making directory: $show/Season $series\n";
			unless(mkdir("$show/Season $series", 0777)) {
				warn "Could not create dir: $!\n";
				# next FILE;
				return 0;
			}
			redo SHOW; # try again now that the dir exists
		}
	}
	# if we are here then we couldn't find a matching show, make DIR
	print "making directory: " . $tvdir . remdot($pureshowname)."\n";
	unless(mkdir($tvdir . remdot($pureshowname), 0777)) {
		warn "Could not create dir: $!\n";
		# next FILE;
		return 0;
	}
	# try again now that the dir exists
	# redo FILE;
	return $REDO_FILE;
}

# move a new Season x directory
sub move_series {
	my ($pureshowname, $showname, $series, $file) = @_;

	print "trying to move $pureshowname season $series directory\n";
	SHOW: foreach my $show (bsd_glob($tvdir.'*')) {
		my $simpleshowname = '^'.fixtitle2($showname).'$';
		if(fixtitle($show) =~ /$showname/i || fixtitle2($show) =~ /$simpleshowname/i) {
			print "found a matching show:\n\t$show\n";
			my $s = $show.'/*';
			my @g=bsd_glob($show);
			foreach my $season (bsd_glob($show.'/*')) {
				if(-d $season.'/' && $season =~ /(?:Season|Series)?\s?0*(\d)$/i && $1 == $series) {
					print "Cannot move season directory: found a matching season already existing:\n\t$season\n";
					return 0;
				}
			}
			# didn't find a matching season, move DIR
			print "moving directory to: $show/Season $series\n";
			dirmove($file, "$show/Season $series") or warn "$show cannot be copied to $show/Season $series : $!";
			if($xbmcwebserver) {
				$new = "$showname Season $series directory";
				displayandupdateinfo($new, $xbmcwebserver);
				$newshows .= "$new\n";
			}
			return 0;
		}
	}
	# if we are here then we couldn't find a matching show, make DIR
	print "making directory: " . $tvdir . remdot($pureshowname)."\n";
	unless(mkdir($tvdir . remdot($pureshowname), 0777)) {
		warn "Could not create dir: $!\n";
		# next FILE;
		return 0;
	}
	# try again now that the dir exists
	# redo FILE;
	return $REDO_FILE;
}