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
#
# Please goto the xbmc forum to discuss SortTV:
# http://forum.xbmc.org/showthread.php?t=75949
# 
# Get the latest version from here:
# http://sourceforge.net/projects/sorttv/files/
# 
# Cliffe's website:
# http://schreuders.org/
# 
# Please consider a $5 donation if you find this program helpful.


use File::Copy::Recursive "dirmove", "dircopy";
use File::Copy;
use File::Glob ':glob';
use LWP::Simple;
use File::Spec::Functions "rel2abs";
use File::Basename;
use FileHandle;
use warnings;
use strict;

my ($sortdir, $tvdir, $nonepisodedir, $xbmcwebserver, $matchtype);
my ($showname, $series, $episode, $pureshowname) = "";
my ($newshows, $new, $log);
my $REDO_FILE = my $moveseasons = "TRUE";
my $usedots = my $rename = my $logfile = my $verbose = my $seasondoubledigit = 0;
my $seasontitle = "Season ";
my $sortby = "MOVE";


out("std", "SortTV\n", "~" x 6,"\n");
get_config_from_file(dirname(rel2abs($0))."/"."sorttv.conf");
process_args(@ARGV);
if(!defined($sortdir) || !defined($tvdir)) {
	out("warn", "Incorrect usage or configuration (missing sort or sort-to directories)\n");
	showhelp();
	exit;
}

$log = FileHandle->new("$logfile", "a") or out("warn", "Could not open log file $logfile: $!\n") if $logfile;

display_info();

FILE: foreach my $file (bsd_glob($sortdir.'*')) {
	$showname = "";
	# Regex for tv show season directory
	if(-d $file && $file =~ /.*\/(.*)(?:Season|Series|$seasontitle)\D?0*(\d+).*/i && $1) {
		$pureshowname = $1;
		if($seasondoubledigit eq "TRUE") {
			$series = sprintf("%02d", $2);
		} else {
			$series = $2;
		}
		$showname = fixtitle($pureshowname);
		if(move_series($pureshowname, $showname, $series, $file) eq $REDO_FILE) {
			redo FILE;
		}
	# Regex for tv show episode: S01E01 or 1x1 or 1 x 1 etc
	} elsif($file =~ /.*\/(.*)(?:\.|\s)[Ss]0*(\d+)\s*[Ee]0*(\d+).*/
	|| $file =~ /.*\/(.*)(?:\.|\s)0*(\d+)\s*[xX]\s*0*(\d+).*/
	  || ($matchtype eq "LIBERAL" && $file =~ /.*\/(.*)(?:\.|\s)0*(\d+)\D*0*(\d+).*/)) {
		$pureshowname = $1;
		$showname = fixtitle($pureshowname);
		if($seasondoubledigit eq "TRUE") {
			$series = sprintf("%02d", $2);
		} else {
			$series = $2;
		}
		$episode = $3;
		if($showname ne "") {
			if(move_episode($pureshowname, $showname, $series, $episode, $file) eq $REDO_FILE) {
				redo FILE;
			}
		}
	} elsif(defined $nonepisodedir) {
		out("std", "moving non-episode $file to $nonepisodedir\n");
		if(-d $file) {
			dirmove($file, $nonepisodedir . filename($file)) or out("warn", "File $file cannot be copied to $nonepisodedir. : $!");
		} else {
			move($file, $nonepisodedir . filename($file)) or out("warn", "File $file cannot be copied to $nonepisodedir. : $!");
		}
	}
}

if($xbmcwebserver && $newshows) {
	sleep(4);
        get "http://$xbmcwebserver/xbmcCmds/xbmcHttp?command=ExecBuiltIn(Notification(,NEW EPISODES NOW AVAILABLE TO WATCH\n$newshows, 7000))";
}

$log->close if(defined $log);
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
		} elsif($arg =~ /^--rename-episodes:(.*)/ || $arg =~ /^-rn:(.*)/) {
			$rename = $1 if $1 eq "TRUE";
		} elsif($arg =~ /^--use-dots-instead-of-spaces:(.*)/ || $arg =~ /^-dots:(.*)/) {
			$usedots = $1 if $1 eq "TRUE";
		} elsif($arg =~ /^--season-title:(.*)/ || $arg =~ /^-st:(.*)/) {
			$seasontitle = $1;
		} elsif($arg =~ /^--sort-by:(.*)/ || $arg =~ /^-by:(.*)/) {
			$sortby = $1;
		} elsif($arg =~ /^--season-double-digits:(.*)/ || $arg =~ /^-sd:(.*)/) {
			$seasondoubledigit = $1 if $1 eq "TRUE";
		} elsif($arg =~ /^--verbose:(.*)/ || $arg =~ /^-v:(.*)/) {
			$verbose = $1;
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
			out("warn", "Incorrect usage (invalid option): $arg\n");
			showhelp();
		}
	}
}

sub get_config_from_file {
	my ($filename) = @_;
	my @arraytoconvert;
	
	if(open (IN, $filename)) {
		out("verbose", "Reading configuration settings from '$filename'\n");
		while(my $in = <IN>) {
			chomp($in);
			if($in =~ /^\s*#/ || $in =~ /^\s*$/) {
				# ignores comments and whitespace
			} elsif($in =~ /(.+):(.+)/) {
				process_args("--$1:$2");
			} else {
				out("warn", "WARNING: this line does not match expected format: '$in'\n");
			}
		}
		close (IN);
	} else {
		out("warn", "Couldn't open config file '$filename': $!\n");
	}
}

sub showhelp {
	my $heredoc = <<END;
Usage: sorttv.pl [OPTIONS] [directory-to-sort directory-to-sort-into]

By default SortTV tries to read the configuration from sorttv.conf
	(an example config file is available online)
You can overwrite any config options with commandline arguments, which match the format of the config file (except that each argument starts with "--")

OPTIONS:
--directory-to-sort:dir
	A directory containing files to sort
	For example, set this to where completed downloads are stored

--directory-to-sort-into:dir
	Where to sort episodes into (dir that will contain dirs for each show)
	This directory will contain the structure (Show)/(Seasons)/(episodes)

--non-episode-dir:dir
	Where to put things that are not episodes
	If this is supplied then files and directories that SortTV does not believe are episodes will be moved here
	If not specified, non-episodes are not moved

--xbmc-web-server:host:port
	host:port for xbmc webserver, to automatically update library when new episodes arrive
	Remember to enable the webserver within xbmc, and "set the content" of your TV directory in xbmc.
	If not specified, xbmc is not updated

--log-file:filepath
	Log to this file
	If not specified, output only goes to stdout (the screen)

--verbose:[TRUE|FALSE]
	Output verbosity. Set to TRUE to show messages describing the decision making process.
	If not specified, FALSE

--read-config-file:filepath
	Secondary config file, overwrites settings loaded so far
	If not specified, only the default config file is loaded (sorttv.conf)

--rename-episodes:[TRUE|FALSE]
	Rename episodes to "show name S01E01.ext" format when moving
	If not specified, FALSE

--use-dots-instead-of-spaces:[TRUE|FALSE]
	Renames episodes to replace spaces with dots
	If not specified, FALSE

--season-title:string
	Season title
	Note: if you want a space it needs to be included
	(eg "Season " -> "Season 1",  "Series "->"Series 1", "Season."->"Season.1")
	If not specified, "Season "

--season-double-digits:[TRUE|FALSE]
	Season format padded to double digits (eg "Season 01" rather than "Season 1")
	If not specified, FALSE

--match-type:[NORMAL|LIBERAL]
	Match type. 
	LIBERAL assumes all files are episodes and tries to extract season and episode number any way possible.
	If not specified, NORMAL

--sort-by:[MOVE|COPY]
	Sort by moving or copying the file. If the file already exists because it was already copied it is silently skipped.
	If not specified, MOVE

EXAMPLES:
The directory-to-sort and directory-to-sort-to can be supplied directly:
To sort a Downloads directory contents into a TV directory
	perl sorttv.pl /home/me/Downloads /home/me/Videos/TV
Alternatively:
	perl sorttv.pl --directory-to-sort:/home/me/Downloads --directory-to-sort-into:/home/me/Videos/TV

To move non-episode files in a separate directory:
	perl sorttv.pl --directory-to-sort:/home/me/Downloads --directory-to-sort-into:/home/me/Videos/TV --non-episode-dir:/home/me/Videos/Non-episodes

To integrate with xbmc (notification and automatic library update):
	perl sorttv.pl --directory-to-sort:/home/me/Downloads --directory-to-sort-into:/home/me/Videos/TV --xbmc-webserver:localhost:8080

And so on...

FURTHER INFORMATION:
Please goto the xbmc forum to discuss SortTV:
http://forum.xbmc.org/showthread.php?t=75949

Get the latest version from here:
http://sourceforge.net/projects/sorttv/files/

Cliffe's website:
http://schreuders.org/

Please consider a \$5 paypal donation if you find this program helpful.

END
	out("std", $heredoc);
	exit;
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
	$title =~ s/,|[. ]the[. ]//ig;
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
	out("std", "$thetime\n"); 
	out("std", "Sorting $sortdir into $tvdir\n"); 
}

sub move_episode {
	my ($pureshowname, $showname, $series, $episode, $file) = @_;

	out("verbose", "trying to move $pureshowname season $series episode $episode\n");
	SHOW: foreach my $show (bsd_glob($tvdir.'*')) {
		my $simpleshowname = '^'.fixtitle2($showname).'$';
		if(fixtitle($show) =~ /$showname/i || fixtitle2($show) =~ /$simpleshowname/i) {
			out("verbose", "found a matching show:\n\t$show\n");
			my $s = $show.'/*';
			my @g=bsd_glob($show);
			foreach my $season (bsd_glob($show.'/*')) {
				if(-d $season.'/' && $season =~ /(?:Season|Series|$seasontitle)?\s?0*(\d+)$/i && $1 == $series) {
					out("verbose", "found a matching season:\n\t$season\n");
					move_an_ep($file, $season, $show, $series, $episode);
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
			out("std", "making season directory: $show/$seasontitle$series\n");
			unless(mkdir("$show/$seasontitle$series", 0777)) {
				out("warn", "Could not create season dir: $!\n");
				# next FILE;
				return 0;
			}
			redo SHOW; # try again now that the dir exists
		}
	}
	# if we are here then we couldn't find a matching show, make DIR
	out("std", "making show directory: " . $tvdir . remdot($pureshowname)."\n");
	unless(mkdir($tvdir . remdot($pureshowname), 0777)) {
		out("warn", "Could not create show dir: $!\n");
		# next FILE;
		return 0;
	}
	# try again now that the dir exists
	# redo FILE;
	return $REDO_FILE;
}

sub move_an_ep {
	my($file, $season, $show, $series, $episode) = @_;
	my $newfilename = filename($file);
	my $newpath;
	
	if($rename) {
		my $ext = "";
		unless(-d $file) {
			$ext = $file;
			$ext =~ s/(.*\.)(.*)/\.$2/;
		}
		$newfilename = sprintf("%s S%02dE%02d%s", $showname, $series, $episode, $ext);
	}
	if($usedots) {
		$newfilename =~ s/\s/./ig;
	}
	$newpath = $season . '/' . $newfilename;
	if(-e $newpath) {
		out("warn", "File $newpath already exists, skipping.\n") if $sortby eq "MOVE";
		return;
	}
	out("std", "$sortby: sorting $file to ", $newpath, "\n");
	if($sortby eq "MOVE") {
		if(-d $file) {
			dirmove($file, $newpath) or out("warn", "File $show cannot be moved to $season. : $!");
		} else {
			move($file, $newpath) or out("warn", "File $show cannot be moved to $season. : $!");
		}
	} elsif($sortby eq "COPY") {
		if(-d $file) {
			dircopy($file, $newpath) or out("warn", "File $show cannot be copied to $season. : $!");
		} else {
			copy($file, $newpath) or out("warn", "File $show cannot be copied to $season. : $!");
		}
	}
}

sub move_a_season {
	my($file, $show, $series) = @_;
	my $newpath = "$show/$seasontitle$series";
	if(-e $newpath) {
		out("warn", "File $newpath already exists, skipping.\n") if $sortby eq "MOVE";
		return;
	}
	out("verbose", "$sortby: sorting directory to: $newpath\n");
	if($sortby eq "MOVE") {
		dirmove($file, "$newpath") or out("warn", "$show cannot be moved to $show/$seasontitle$series: $!");
	} elsif($sortby eq "COPY") {
		dircopy($file, "$newpath") or out("warn", "$show cannot be copied to $show/$seasontitle$series: $!");
	}
}

# move a new Season x directory
sub move_series {
	my ($pureshowname, $showname, $series, $file) = @_;

	out("verbose", "trying to move $pureshowname season $series directory\n");
	SHOW: foreach my $show (bsd_glob($tvdir.'*')) {
		my $simpleshowname = '^'.fixtitle2($showname).'$';
		if(fixtitle($show) =~ /$showname/i || fixtitle2($show) =~ /$simpleshowname/i) {
			out("verbose", "found a matching show:\n\t$show\n");
			my $s = $show.'/*';
			my @g=bsd_glob($show);
			foreach my $season (bsd_glob($show.'/*')) {
				if(-d $season.'/' && $season =~ /(?:Season|Series|$seasontitle)?\s?0*(\d)$/i && $1 == $series) {
					out("warn", "Cannot move season directory: found a matching season already existing:\n\t$season\n");
					return 0;
				}
			}
			# didn't find a matching season, move DIR
			move_a_season($file, $show, $series);
			if($xbmcwebserver) {
				$new = "$showname Season $series directory";
				displayandupdateinfo($new, $xbmcwebserver);
				$newshows .= "$new\n";
			}
			return 0;
		}
	}
	# if we are here then we couldn't find a matching show, make DIR
	out("std", "making directory: " . $tvdir . remdot($pureshowname)."\n");
	unless(mkdir($tvdir . remdot($pureshowname), 0777)) {
		out("warn", "Could not create show dir: $!\n");
		# next FILE;
		return 0;
	}
	# try again now that the dir exists
	# redo FILE;
	return $REDO_FILE;
}

sub out {
	my ($type, @msg) = @_;
	
	if($type eq "verbose") {
		return if $verbose ne "TRUE";
		print @msg;
		print $log @msg if(defined $log);
	}elsif($type eq "std") {
		print @msg;
		print $log @msg if(defined $log);
	} elsif($type eq "warn") {
		warn @msg;
		print $log @msg if(defined $log);
	}
}
