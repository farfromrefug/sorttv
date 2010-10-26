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
# schmoko - xbmc forum
# CoinTos - xbmc forum
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
use TVDB::API;
use File::Find;
use Text::Capitalize;
use FileHandle;
use warnings;
use strict;

my ($sortdir, $tvdir, $nonepisodedir, $xbmcwebserver, $matchtype);
my ($showname, $series, $episode, $pureshowname) = "";
my ($newshows, $new, $log);
my $REDO_FILE = my $moveseasons = "TRUE";
my $usedots = my $rename = my $logfile = my $verbose = my $seasondoubledigit = my $removesymlinks = my $needshowexist = my $windowsnames = 0;
my $seasontitle = "Season ";
my $sortby = "MOVE";
my $renameformat = "[SHOW_NAME] - [EP1][EP_NAME1]";
my $treatdir = "RECURSIVELY_SORT_CONTENTS";
my $fetchimages = "NEW_SHOWS";
my $imagesformat = "POSTER";
my @showrenames;
my $scriptpath = dirname(rel2abs($0));
my $tvdblanguage = "en";
my $tvdb;

out("std", "SortTV\n", "~" x 6,"\n");
get_config_from_file("$scriptpath/sorttv.conf");
process_args(@ARGV);
if(!defined($sortdir) || !defined($tvdir)) {
	out("warn", "Incorrect usage or configuration (missing sort or sort-to directories)\n");
	out("warn", "run 'perl sorttv.pl --help' for more information about how to use SortTV");
	exit;
}

# if uses thetvdb, set it up
if($renameformat =~ /\[EP_NAME\d]/i || $fetchimages ne "FALSE") {
	my $TVDBAPIKEY = "FDDBDB916D936956";
	$tvdb = TVDB::API::new($TVDBAPIKEY);

	$tvdb->setLang($tvdblanguage);
	my $hashref = $tvdb->getAvailableMirrors();
	$tvdb->setMirrors($hashref);
	$tvdb->chooseMirrors();
	unless (-e "$scriptpath/.cache" || mkdir "$scriptpath/.cache") {
		out("warn", "WARN: Could not create cache dir: $scriptpath/cache $!\n");
		exit;
	}
	$tvdb->setCacheDB("$scriptpath/.cache/.tvdb.db");
	$tvdb->setUserAgent("SortTV");
	$tvdb->setBannerPath("$scriptpath/.cache/");
}

$log = FileHandle->new("$logfile", "a") or out("warn", "WARN: Could not open log file $logfile: $!\n") if $logfile;

display_info();

sort_directory($sortdir);

if($xbmcwebserver && $newshows) {
	sleep(4);
        get "http://$xbmcwebserver/xbmcCmds/xbmcHttp?command=ExecBuiltIn(Notification(,NEW EPISODES NOW AVAILABLE TO WATCH\n$newshows, 7000))";
}

$log->close if(defined $log);
exit;

sub sort_directory {
	my ($sortd) = @_;
	FILE: foreach my $file (bsd_glob($sortd.'*')) {
		$showname = "";
		# Regex for tv show season directory
		if(-l $file) {
			if($removesymlinks eq "TRUE") {
				out("std", "DELETE: Removing symlink: $file\n");
				unlink($file) or out("warn", "WARN: Could not delete symlink $file: $!\n");
			}
			# otherwise file is a symlink, ignore
		} elsif(-d $file && $treatdir eq "IGNORE") {
			# ignore directories
		} elsif(-d $file && $treatdir eq "RECURSIVELY_SORT_CONTENTS") {
			sort_directory("$file/");
			# removes any empty directories from the to-sort directory and sub-directories
			finddepth(sub{rmdir},"$sortd");
		} elsif(-d $file && $file =~ /.*\/(.*)(?:Season|Series|$seasontitle)\D?0*(\d+).*/i && $1) {
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
		} elsif(filename($file) =~ /(.*)(?:\.|\s)[Ss]0*(\d+)\s*[Ee]0*(\d+).*/
		|| filename($file) =~ /(.*)(?:\.|\s)0*(\d+)\s*[xX]\s*0*(\d+).*/
		|| ($matchtype eq "LIBERAL" && filename($file) =~ /(.*)(?:\.|\s)0*(\d+)\D*0*(\d+).*/)) {
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
			my $newname = $file;
			$newname =~ s/$sortdir//;
			$newname = escape_myfilename($newname);
			out("std", "MOVING NON-EPISODE: $file to $nonepisodedir$newname\n");
			if(-d $file) {
				dirmove($file, $nonepisodedir . $newname) or out("warn", "WARN: File $file cannot be copied to $nonepisodedir. : $!");
			} else {
				move($file, $nonepisodedir . $newname) or out("warn", "WARN: File $file cannot be copied to $nonepisodedir. : $!");
			}
		}
	}
}


sub process_args {
	foreach my $arg (@_) {
		if($arg =~ /^--non-episode-dir:(.*)/ || $arg =~ /^-ne:(.*)/) {
			if(-e $1) {
				$nonepisodedir = $1;
				# append a trailing / if it's not there
				$nonepisodedir .= '/' if($nonepisodedir !~ /\/$/);
			} else {
				out("warn", "WARN: Non-episode directory does not exist ($1)\n");
			}
		} elsif($arg =~ /^--xbmc-web-server:(.*)/ || $arg =~ /^-xs:(.*)/) {
			$xbmcwebserver = $1;
		} elsif($arg =~ /^--match-type:(.*)/ || $arg =~ /^-mt:(.*)/) {
			$matchtype = $1;
		} elsif($arg =~ /^--treat-directories:(.*)/ || $arg =~ /^-td:(.*)/) {
			$treatdir = $1;
		} elsif($arg =~ /^--show-name-substitute:(.*-->.*)/ || $arg =~ /^-sub:(.*-->.*)/) {
			push @showrenames, $1;
		} elsif($arg =~ /^--log-file:(.*)/ || $arg =~ /^-o:(.*)/) {
			$logfile = $1;
		} elsif($arg =~ /^--rename-episodes:(.*)/ || $arg =~ /^-rn:(.*)/) {
			$rename = $1;
		} elsif($arg =~ /^--lookup-language:(.*)/ || $arg =~ /^-lang:(.*)/) {
			$tvdblanguage = $1;
		} elsif($arg =~ /^--fetch-images:(.*)/ || $arg =~ /^-fi:(.*)/) {
			$fetchimages = $1;
		} elsif($arg =~ /^--images-format:(.*)/ || $arg =~ /^-if:(.*)/) {
			$imagesformat = $1;
		} elsif($arg =~ /^--require-show-directories-already-exist:(.*)/ || $arg =~ /^-rs:(.*)/) {
			$needshowexist = $1;
		} elsif($arg =~ /^--force-windows-compatible-filenames:(.*)/ || $arg =~ /^-fw:(.*)/) {
			$windowsnames = $1;
		} elsif($arg =~ /^--rename-format:(.*)/ || $arg =~ /^-rf:(.*)/) {
			$renameformat = $1;
		} elsif($arg =~ /^--remove-symlinks:(.*)/ || $arg =~ /^-rs:(.*)/) {
			$removesymlinks = $1;
		} elsif($arg =~ /^--use-dots-instead-of-spaces:(.*)/ || $arg =~ /^-dots:(.*)/) {
			$usedots = $1;
		} elsif($arg =~ /^--season-title:(.*)/ || $arg =~ /^-st:(.*)/) {
			$seasontitle = $1;
		} elsif($arg =~ /^--sort-by:(.*)/ || $arg =~ /^-by:(.*)/) {
			$sortby = $1;
		} elsif($arg =~ /^--season-double-digits:(.*)/ || $arg =~ /^-sd:(.*)/) {
			$seasondoubledigit = $1;
		} elsif($arg =~ /^--verbose:(.*)/ || $arg =~ /^-v:(.*)/) {
			$verbose = $1;
		} elsif($arg =~ /^--read-config-file:(.*)/ || $arg =~ /^-conf:(.*)/) {
			get_config_from_file($1);
		} elsif($arg =~ /^--directory-to-sort:(.*)/ || $arg =~ /^-sort:(.*)/) {
			if(-e $1) {
				$sortdir = $1;
				# append a trailing / if it's not there
				$sortdir .= '/' if($sortdir !~ /\/$/);
			} else {
				out("warn", "WARN: Directory to sort does not exist ($1)\n");
			}
		} elsif($arg =~ /^--directory-to-sort-into:(.*)/ || $arg =~ /^-sortto:(.*)/) {
			if(-e $1) {
				$tvdir = $1;
				# append a trailing / if it's not there
				$tvdir .= '/' if($tvdir !~ /\/$/);
			} else {
				out("warn", "WARN: Directory to sort into does not exist ($1)\n");
			}
		} elsif($arg eq "--help" || $arg eq "-h") {
			showhelp();
		} elsif(!defined($sortdir)) {
			if(-e $arg) {
				$sortdir = $arg;
				# append a trailing / if it's not there
				$sortdir .= '/' if($sortdir !~ /\/$/);
			} else {
				out("warn", "WARN: Directory to sort does not exist ($arg)\n");
			}
		} elsif(!defined($tvdir)) {
			if(-e $arg) {
				$tvdir = $arg;
				# append a trailing / if it's not there
				$tvdir .= '/' if($tvdir !~ /\/$/);
			} else {
				out("warn", "Directory to sort into does not exist ($arg)\n");
			}
		} else {
			out("warn", "WARN: Incorrect usage (invalid option): $arg\n");
			out("warn", "INFO: run 'perl sorttv.pl --help' for more information about how to use SortTV");
		}
	}
}

sub get_config_from_file {
	my ($filename) = @_;
	my @arraytoconvert;
	
	if(open (IN, $filename)) {
		out("verbose", "INFO: Reading configuration settings from '$filename'\n");
		while(my $in = <IN>) {
			chomp($in);
			if($in =~ /^\s*#/ || $in =~ /^\s*$/) {
				# ignores comments and whitespace
			} elsif($in =~ /(.+):(.+)/) {
				process_args("--$1:$2");
			} else {
				out("warn", "WARN: this line does not match expected format: '$in'\n");
			}
		}
		close (IN);
	} else {
		out("warn", "WARN: Couldn't open config file '$filename': $!\n");
		out("warn", "INFO: An example config file is available and can make using SortTV easier\n");
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

--rename-format:{formatstring}
	the format to use if renaming to a new format (as specified above)
	Hint: including the Episode Title as part of the name slows the process down a bit since titles are retrieved from thetvdb.com
	The formatstring can be made up of:
	[SHOW_NAME]: "My Show"
	[EP1]: "S01E01"
	[EP2]: "1x1"
	[EP3]: "1x01"
	[EP_NAME1] " - Episode Title"
	[EP_NAME2] ".Episode Title"
	If not specified the format is "[SHOW_NAME] - [EP1][EP_NAME1]"
	For example:
		for "My Show S01E01 - Episode Title" (this is the default)
		--rename-format:[SHOW_NAME] - [EP1][EP_NAME1]
		for "My Show.S01E01.Episode Title"
		--rename-format:[SHOW_NAME].[EP1][EP_NAME2]
		
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

--sort-by:[MOVE|COPY|MOVE-AND-LEAVE-SYMLINK-BEHIND|LEAVE-AND-PLACE-SYMLINK]
	Sort by moving or copying the file. If the file already exists because it was already copied it is silently skipped.
	The MOVE-AND-LEAVE-SYMLINK-BEHIND option may be handy if you want to continue to seed after sorting, this leaves a symlink in place of the newly moved file.
	PLACE-SYMLINK does not move the original file, but places a symlink in the sort-to directory (probably not what you want)
	If not specified, MOVE

--treat-directories:[AS_FILES_TO_SORT|RECURSIVELY_SORT_CONTENTS|IGNORE]
	How to treat directories. 
	AS_FILES_TO_SORT - sorts directories, moving entire directories that represents an episode, also detects and moves directories of entire seasons
	RECURSIVELY_SORT_CONTENTS - doesn't move directories, just their contents, including subdirectories
	IGNORE - ignores directories
	If not specified, RECURSIVELY_SORT_CONTENTS
	
--require-show-directories-already-exist:[TRUE|FALSE]
	Only sort into show directories that already exist
	This may be helpful if you have multiple destination directories. Just set up all the other details in the conf file, 
	and specify the destination directory when invoking the script. Only episodes that match existing directories in the destination will be moved.
	If this is false, then new directories are created for shows that dont have a directory.
	If not specified, FALSE
	
--remove-symlinks:[TRUE|FALSE]
	Deletes symlinks from the directory to sort while sorting.
	This may be helpful if you want to remove all the symlinks you previously left behind using --sort-by:MOVE-AND-LEAVE-SYMLINK-BEHIND
	You could schedule "perl sorttv.pl --remove-symlinks:TRUE" to remove these once a week/month
	If this option is enabled and used at the same time as --sort-by:MOVE-AND-LEAVE-SYMLINK-BEHIND, 
	 then only the previous links will be removed, and new ones may also be created
	If not specified, FALSE

--show-name-substitute:NAME1-->NAME2
	Substitutes files equal to NAME1 for NAME2
	This argument can be repeated to add multiple rules for substitution

--force-windows-compatible-filenames:[TRUE|FALSE]
	Forces MSWindows compatible file names, even when run on other platforms such as Linux
	This may be helpful if you are writing to a Windows share from a Linux system
	If not specified, FALSE

--lookup-language:[en|...]
	Set language for thetvdb lookups, this effects episode titles etc
	Valid values include: it, zh, es, hu, nl, pl, sl, da, de, el, he, sv, eng, fi, no, fr, ru, cs, en, ja, hr, tr, ko, pt
	If not specified, en (English)

--fetch-images:[NEW_SHOWS|FALSE]
	Download images for shows, seasons, and episodes from thetvdb
	Downloaded images are copied into the sort-to (destination) directory.
	NEW_SHOWS - When new shows, seasons, or episodes are created the associated images are downloaded
	FALSE - No images are downloaded
	if not specified, NEW_SHOWS

--images-format:POSTER
	Sets the image format to use, poster or banner.
	POSTER/BANNER
	if not specified, POSTER


EXAMPLES:
Does a sort, as configured in sorttv.conf:
	perl sorttv.pl

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

	# pop up a notification on xbmc
	# xbmc.executebuiltin('XBMC.Notification(New content found, ' + filename + ', 2000)')
	get "http://$xbmcwebserver/xbmcCmds/xbmcHttp?command=ExecBuiltIn(Notification(NEW EPISODE, $show, 7000))";
}

# replaces ".", "_" and removes "the" and ","
# removes numbers and spaces
# removes the dir path
sub fixtitle {
	my ($title) = @_;
	$title = substitute_name($title);
	$title =~ s/,|\.the\.|\bthe\b//ig;
	$title =~ s/\.and\.|\band\b//ig;
	$title =~ s/&|\+//ig;
	$title =~ s/(.*\/)(.*)/$2/;
	$title = remdot($title);
	$title =~ s/\d|\s|\(|\)//ig;
	return $title;
}

# substitutes show names as configured
sub substitute_name {
	my ($from) = @_;
	foreach my $substitute (@showrenames) {
		if($substitute =~ /(.*)-->(.*)/) {
			my $subsrc = $1, my $subdest = $2;
			if($from =~ /^\Q$subsrc\E$/i) {
				return $subdest;
			}
		}
	}
	# if no matches, returns unchanged
	return $from;
}

# removes dots and underscores for creating dirs
sub remdot {
	my ($title) = @_;
	$title =~ s/\./ /ig;
	$title =~ s/_/ /ig;
	$title =~ s/-//ig;
	$title =~ s/'//ig;
	# don't start or end on whitespace
	$title =~ s/\s$//ig;
	$title =~ s/^\s//ig;
	return $title;
}

# removes path
sub filename {
	my ($title) = @_;
	$title =~ s/(.*\/)(.*)/$2/;
	return $title;
}

sub escape_myfilename {
	my ($name) = @_;
	if($^O =~ /MSWin/ || $windowsnames eq "TRUE") {
		$name =~ s/[\\\/:*?\"<>|]/-/g;
	} else {
		$name =~ s/[\\\/\"<>|]/-/g;
	}
	return $name;
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

	out("verbose", "INFO: trying to move $pureshowname season $series episode $episode\n");
	SHOW: foreach my $show (bsd_glob($tvdir.'*')) {
		my $subshowname = fixtitle(escape_myfilename(substitute_name($showname)));
		if(fixtitle($show) =~ /^\Q$showname\E$/i || fixtitle(escape_myfilename(substitute_name(filename($show)))) =~ /^\Q$subshowname\E$/i) {
			out("verbose", "INFO: found a matching show:\n\t$show\n");
			my $s = $show.'/*';
			my @g=bsd_glob($show);
			foreach my $season (bsd_glob($show.'/*')) {
				if(-d $season.'/' && $season =~ /(?:Season|Series|$seasontitle)?\s?0*(\d+)$/i && $1 == $series) {
					out("verbose", "INFO: found a matching season:\n\t$season\n");
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
			out("std", "INFO: making season directory: $show/$seasontitle$series\n");
			my $newpath = "$show/$seasontitle$series";
			if(mkdir($newpath, 0777)) {
				fetchseasonimages(substitute_name(remdot($pureshowname)), $show, $series, $newpath) if $fetchimages ne "FALSE";
				redo SHOW; # try again now that the dir exists
			} else {
				out("warn", "WARN: Could not create season dir: $!\n");
				# next FILE;
				return 0;
			}
		}
	}
	if($needshowexist ne "TRUE") {
		# if we are here then we couldn't find a matching show, make DIR
		my $newshowdir = $tvdir .escape_myfilename(substitute_name(capitalize_title(remdot($pureshowname), PRESERVE_ALLCAPS => 1)));
		out("std", "INFO: making show directory: $newshowdir\n");
		if(mkdir($newshowdir, 0777)) {
			fetchshowimages(substitute_name(remdot($pureshowname)), $newshowdir) if $fetchimages ne "FALSE";
			# try again now that the dir exists
			# redo FILE;
			return $REDO_FILE;
		} else {
			out("warn", "WARN: Could not create show dir: $newshowdir:$!\n");
			# next FILE;
			return 0;
		}
	} else {
		out("verbose", "SKIP: Show directory does not exist: " . $tvdir . escape_myfilename(substitute_name(remdot($pureshowname)))."\n");
		# next FILE;
		return 0;
	}
}

sub fetchshowimages {
	my ($fetchname, $newshowdir) = @_;
	out("std", "DOWNLOAD: downloading images for $fetchname\n");
	my $banner = $tvdb->getSeriesBanner($fetchname);
	my $fanart = $tvdb->getSeriesFanart($fetchname);
	my $poster = $tvdb->getSeriesPoster($fetchname);
	copy ("$scriptpath/.cache/$fanart", "$newshowdir/fanart.jpg") if $fanart && -e "$scriptpath/.cache/$fanart";
	copy ("$scriptpath/.cache/$banner", "$newshowdir/banner.jpg") if $banner && -e "$scriptpath/.cache/$banner";
	copy ("$scriptpath/.cache/$poster", "$newshowdir/poster.jpg") if $poster && -e "$scriptpath/.cache/$poster";
	my $ok = eval{symlink "$newshowdir/poster.jpg", "$newshowdir/folder.jpg" if $poster && -e "$scriptpath/.cache/$poster" && $imagesformat eq "POSTER";};
	if(!defined $ok) {copy "$newshowdir/poster.jpg", "$newshowdir/folder.jpg" if $poster && -e "$scriptpath/.cache/$poster" && $imagesformat eq "POSTER";};
	$ok = eval{symlink "$newshowdir/banner.jpg", "$newshowdir/folder.jpg" if $banner && -e "$scriptpath/.cache/$banner" && $imagesformat eq "BANNER";};
	if(!defined $ok) {copy "$newshowdir/banner.jpg", "$newshowdir/folder.jpg" if $banner && -e "$scriptpath/.cache/$banner" && $imagesformat eq "BANNER";};
}

sub fetchseasonimages {
	my ($fetchname, $newshowdir, $season, $seasondir) = @_;
	out("std", "DOWNLOAD: downloading season image for $fetchname\n");
	my $banner = $tvdb->getSeasonBanner($fetchname, $season);
	my $bannerwide = $tvdb->getSeasonBannerWide($fetchname, $season);
	my $snum = sprintf("%02d", $season);
	copy ("$scriptpath/.cache/$banner", "$newshowdir/season${snum}.jpg") if $banner && -e "$scriptpath/.cache/$banner" && $imagesformat eq "POSTER";
	copy ("$scriptpath/.cache/$bannerwide", "$newshowdir/season${snum}.jpg") if $bannerwide && -e "$scriptpath/.cache/$bannerwide" && $imagesformat eq "BANNER";
	my $ok = eval{symlink "$newshowdir/season$snum.jpg", "$seasondir/folder.jpg" if -e "$newshowdir/season$snum.jpg";};
	if(!defined $ok) {copy "$newshowdir/season$snum.jpg", "$seasondir/folder.jpg" if -e "$newshowdir/season$snum.jpg";};
}

sub fetchepisodeimage {
	my ($fetchname, $newshowdir, $season, $seasondir, $episode, $newfilename) = @_;
	# if the episode was moved (or already existed)
	if(-e "$seasondir/$newfilename") {
		my $epimage = $tvdb->getEpisodeBanner($fetchname, $season, $episode);
		my $newimagepath = "$seasondir/$newfilename";
		$newimagepath =~ s/(.*)(\..*)/$1.tbn/;
		copy ("$scriptpath/.cache/$epimage", $newimagepath) if $epimage && -e "$scriptpath/.cache/$epimage";
	}
}

sub move_an_ep {
	my($file, $season, $show, $series, $episode) = @_;
	my $newfilename = filename($file);
	my $newpath;
	
	if($rename eq "TRUE") {
		my $ext = my $eptitle = "";
		unless(-d $file) {
			$ext = $file;
			$ext =~ s/(.*\.)(.*)/\.$2/;
		}
		if($renameformat =~ /\[EP_NAME(\d)]/i) {
			out("verbose", "INFO: Fetching episode title for ", substitute_name(remdot($pureshowname)), " Season $series Episode $episode.\n");
			my $name = $tvdb->getEpisodeName(substitute_name(remdot($pureshowname)), $series, $episode);
			if($name) {
				$eptitle = " - $name" if $1 == 1;
				$eptitle = ".$name" if $1 == 2;
			} else {
				out("warn", "WARN: Could not get episode title for ", substitute_name(remdot($pureshowname)), " Season $series Episode $episode.\n");
			}
		}
		my $sname = substitute_name(capitalize_title(remdot($pureshowname), PRESERVE_ALLCAPS => 1));
		my $ep1 = sprintf("S%02dE%02d", $series, $episode);
		my $ep2 = sprintf("%dx%d", $series, $episode);
		my $ep3 = sprintf("%dx%02d", $series, $episode);
		# create the new file name
		$newfilename = $renameformat;
		$newfilename =~ s/\[SHOW_NAME]/$sname/ig;
		$newfilename =~ s/\[EP1]/$ep1/ig;
		$newfilename =~ s/\[EP2]/$ep2/ig;
		$newfilename =~ s/\[EP3]/$ep3/ig;
		$newfilename =~ s/\[EP_NAME\d]/$eptitle/ig;
		$newfilename .= $ext;
		# make sure it is filesystem friendly:
		$newfilename = escape_myfilename($newfilename, "-");
	}
	if($usedots eq "TRUE") {
		$newfilename =~ s/\s/./ig;
	}

	$newpath = $season . '/' . $newfilename;
	if(-e $newpath) {
		if(filename($file) =~ /repack|proper/i) {
			out("warn", "OVERWRITE: Repack/proper version.\n");
		} else {
			out("warn", "SKIP: File $newpath already exists, skipping.\n") unless($sortby eq "COPY" || $sortby eq "PLACE-SYMLINK");
			return;
		}
	}
	out("std", "$sortby: sorting $file to ", $newpath, "\n");
	if($sortby eq "MOVE" || $sortby eq "MOVE-AND-LEAVE-SYMLINK-BEHIND") {
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
	} elsif($sortby eq "PLACE-SYMLINK") {
		symlink($file, $newpath) or out("warn", "File $file cannot be symlinked to $newpath. : $!");
	}
	# have moved now link
	if($sortby eq "MOVE-AND-LEAVE-SYMLINK-BEHIND") {
		symlink($newpath, $file) or out("warn", "File $newpath cannot be symlinked to $file. : $!");
	}
	
	fetchepisodeimage(substitute_name(remdot($pureshowname)), $show, $series, $season, $episode, $newfilename) if $fetchimages ne "FALSE";
	
}

sub move_a_season {
	my($file, $show, $series) = @_;
	my $newpath = $show."/".escape_myfilename("$seasontitle$series", "-");
	if(-e $newpath) {
		out("warn", "SKIP: File $newpath already exists, skipping.\n") unless($sortby eq "COPY" || $sortby eq "PLACE-SYMLINK");
		return;
	}
	print "$sortby SEASON: $file to $newpath\n";	
	out("verbose", "$sortby: sorting directory to: $newpath\n");
	if($sortby eq "MOVE" || $sortby eq "MOVE-AND-LEAVE-SYMLINK-BEHIND") {
		dirmove($file, "$newpath") or out("warn", "$show cannot be moved to $show/$seasontitle$series: $!");
	} elsif($sortby eq "COPY") {
		dircopy($file, "$newpath") or out("warn", "$show cannot be copied to $show/$seasontitle$series: $!");
	} elsif($sortby eq "PLACE-SYMLINK") {
		symlink($file, $newpath) or out("warn", "File $file cannot be symlinked to $newpath. : $!");
	}
	if($sortby eq "MOVE-AND-LEAVE-SYMLINK-BEHIND") {
		symlink($newpath, $file) or out("warn", "File $newpath cannot be symlinked to $file. : $!");
	}
}

# move a new Season x directory
sub move_series {
	my ($pureshowname, $showname, $series, $file) = @_;

	out("verbose", "INFO: trying to move $pureshowname season $series directory\n");
	SHOW: foreach my $show (bsd_glob($tvdir.'*')) {
		if(fixtitle($show) =~ /^\Q$showname\E$/i) {
			out("verbose", "INFO: found a matching show:\n\t$show\n");
			my $s = $show.'/*';
			my @g=bsd_glob($show);
			foreach my $season (bsd_glob($show.'/*')) {
				if(-d $season.'/' && $season =~ /(?:Season|Series|$seasontitle)?\s?0*(\d)$/i && $1 == $series) {
					out("warn", "SKIP: Cannot move season directory: found a matching season already existing:\n\t$season\n");
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
	if($needshowexist ne "TRUE") {
		# if we are here then we couldn't find a matching show, make DIR
		my $newshowdir = $tvdir .escape_myfilename(substitute_name(capitalize_title(remdot($pureshowname), PRESERVE_ALLCAPS => 1)));
		out("std", "INFO: making show directory: $newshowdir\n");
		if(mkdir($newshowdir, 0777)) {
			fetchshowimages(substitute_name(remdot($pureshowname)), $newshowdir) if $fetchimages ne "FALSE";
			# try again now that the dir exists
			# redo FILE;
			return $REDO_FILE;
		} else {
			out("warn", "WARN: Could not create show dir: $newshowdir:$!\n");
			# next FILE;
			return 0;
		}
	} else {
		out("verbose", "SKIP: Show directory does not exist: " . $tvdir . escape_myfilename(substitute_name(remdot($pureshowname)))."\n");
		# next FILE;
		return 0;
	}
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
