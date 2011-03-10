#!/usr/bin/perl

# SortTV
# Copyleft (ↄ) 2010-2011
# Z. Cliffe Schreuders
#
# Sorts tv shows into tvshow/series directories;
# If the dirs don't exist they are created;
# Updates xbmc via the web interface;
# Unsorted files are moved to a dir if specifed;
# Lots of other features.
#
# Other contributers:
# salithus - xbmc forum
# schmoko - xbmc forum
# CoinTos - xbmc forum
# gardz - xbmc forum
# Patrick Cole - z@amused.net
#
# Please goto the xbmc forum to discuss SortTV:
# http://forum.xbmc.org/showthread.php?t=75949
# 
# Get the latest version from here:
# http://sourceforge.net/projects/sorttv/files/
# 
# Cliffe's website:
# http://z.cliffe.schreuders.org/
# 
# Please consider a $5 donation if you find this program helpful.
# http://sourceforge.net/donate/index.php?group_id=330009

# This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.

use File::Copy::Recursive "dirmove", "dircopy";
use File::Copy;
use File::Glob ':glob';
use LWP::Simple;
use File::Spec::Functions "rel2abs";
use File::Basename;
use TVDB::API;
use File::Find;
use File::Path qw(make_path);
use FileHandle;
use warnings;
use strict;
use Fcntl ':flock';
use Getopt::Long;
use Getopt::Long qw(GetOptionsFromString);

my $man = 0;
my $help = 0;

my ($sortdir, $tvdir, $nonepisodedir, $xbmcwebserver, $matchtype);
my ($showname, $series, $episode, $pureshowname) = "";
my ($newshows, $new, $log);
my ( @whitelist, @blacklist, @sizerange);
my (%showrenames, %showtvdbids);
my $REDO_FILE = my $moveseasons = my $windowsnames = my $tvdbrename = my $lookupseasonep = my $extractrar = "TRUE";
my $usedots = my $rename = my $verbose = my $seasondoubledigit = my $removesymlinks = my $needshowexist = my $flattennonepisodefiles = "FALSE";
my $logfile = 0;
my $createundoscript = 0;
my $undoscriptname = "undolastsort.pl";
my $undoscript = 0;
my $seasontitle = "Season ";
my $sortby = "MOVE";
my $sortolderthandays = 0;
my $ifexists = "SKIP";
my $renameformat = "[SHOW_NAME] - [EP1][EP_NAME1]";
my $treatdir = "RECURSIVELY_SORT_CONTENTS";
my $fetchimages = "NEW_SHOWS";
my $imagesformat = "POSTER";
my $scriptpath = dirname(rel2abs($0));
my $tvdblanguage = "en";
my $tvdb;
my $forceeptitle = ""; # HACK for limitation in TVDB API module

out("std", "SortTV\n", "~" x 6,"\n");

# ensure only one copy running at a time
if(open SELF, "< $0") {
	flock SELF, LOCK_EX | LOCK_NB  or die "SortTV is already running, exiting.\n";
}

my @optionlist = ("non-episode-dir|ne=s"    => sub {
                                                $nonepisodedir = $_[1];
                                                if(-e $nonepisodedir) {
                                                    
                                                    # append a trailing / if it's not there
                                                    $nonepisodedir .= '/' if($nonepisodedir !~ /\/$/);
                                                } else {
                                                    out("warn", "WARN: Non-episode directory does not exist ($nonepisodedir)\n");
                                                }
                                                if($^O =~ /MSWin/ && $fetchimages eq "TRUE") {
                                                    out("warn", "WARN: The Windows version of the TVDB API module does not support image                            downloads.\nRECOMMENDATION: edit your config file to disable this feature.\n");
                                                }},
            "xbmc-web-server|xs=s"    => \$xbmcwebserver,
            "match-type|ms=s" => \$matchtype,
            "flatten-non-eps|fne=s" => \$flattennonepisodefiles,
            "treat-directories|td=s" => \$treatdir,
            "if-file-exists|e=s" => \$ifexists,
            "extract-compressed-before-sorting|rar=s" => \$extractrar,
            "show-name-substitute|fne=s" => sub { 
                                                        if($_[1] =~ /(.*)-->(.*)/) {
                                                            $showrenames{$1} = $2;
                                                        }},
            "whitelist|white=s" => sub { # puts the shell pattern in as a regex
                                                    push @whitelist, glob2pat($_[1]); },
            "blacklist|black=s" => sub { # puts the shell pattern in as a regex
                                                    push @blacklist, glob2pat($_[1]); },
            "tvdb-id-substitute|tis=s" => sub { 
                                                        if($_[1] =~ /(.*)-->(.*)/) {
                                                            $showtvdbids{$1} = $2;
                                                        }},
            "log-file|o=s" => \$logfile,
            "create-undo-script|undo" => \$createundoscript,
            "fetch-show-title|fst=s" => \$tvdbrename,
            "rename-episodes|rn=s" => \$rename,
            "lookup-language|lang=s" => \$tvdblanguage,
            "fetch-images|fi=s" => \$fetchimages,
            "images-format|im=s" => \$imagesformat,
            "require-show-directories-already-exist|rs=s" => \$needshowexist,
            "force-windows-compatible-filenames|fw=s" => \$windowsnames,
            "rename-format|rf=s" => \$renameformat,
            "remove-symlinks|rs=s" => \$removesymlinks,
            "use-dots-instead-of-spaces|dots=s" => \$usedots,
            "sort-by|by=s" => \$sortby,
            "sort-only-older-than-days|age=i" => \$sortolderthandays,
            "season-double-digits|sd=s" => \$seasondoubledigit,
            "match-files-based-on-tvdb-lookups|tlookup=s" => \$lookupseasonep,
            "season-title|st=s" => \$seasontitle,
            "verbose|v=s" => \$verbose,
            "filesize-range|fsrange=f{2}" => sub {
                                                    # Extract the min & max values, can mix and match postfixes
                                                    my $minfilesize = $_[1];
                                                    my $maxfilesize = $_[2];
                                                    $minfilesize =~ s/MB//;
                                                    $maxfilesize =~ s/MB//;
                                                    # Fix filesizes passed in to all MB
                                                    if ($minfilesize =~ /(.*)GB/) {
                                                        $minfilesize = $1 * 1024;
                                                    }
                                                    if ($maxfilesize =~ /(.*)GB/) {
                                                        $maxfilesize = $1 * 1024;
                                                    }
                                                    # Save as MB range
                                                    push @sizerange, "$minfilesize-$maxfilesize";} ,
            "no-network|nn" => sub {
                                                  $xbmcwebserver = "";
                                                    $tvdbrename = $fetchimages = $lookupseasonep = "FALSE";
                                                    $renameformat =~ s/\[EP_NAME\d\]//;},
            "read-config-file|conf=s" => sub { get_config_from_file($_[1]); },
            "directory-to-sort|sort=s" => sub { my $sortd = $_[1];
                                                # use Unix slashes
                                                $sortd =~ s/\\/\//g;
                                                if(-e $sortd) {
                                                    $sortdir = $sortd;
                                                    # append a trailing / if it's not there
                                                    $sortdir .= '/' if($sortdir !~ /\/$/);
                                                } else {
                                                    out("warn", "WARN: Directory to sort does not exist ($1)\n");
                                                }},
            "directory-to-sort-into|sortto=s" => sub { my $sortt = $_[1];
                                                        # use Unix slashes
                                                        $sortt =~ s/\\/\//g;
                                                        if($sortt eq "KEEP_IN_SAME_DIRECTORIES") {
                                                            $nonepisodedir = "";
                                                            $tvdir = "KEEP_IN_SAME_DIRECTORIES";
                                                        } elsif(-e $sortt) {
                                                            $tvdir = $sortt;
                                                            # append a trailing / if it's not there
                                                            $tvdir .= '/' if($tvdir !~ /\/$/);
                                                        } else {
                                                            out("warn", "WARN: Directory to sort into does not exist ($1)\n");
                                                        }},
            "h|help|?" => \$help, man => \$man);
            


get_config_from_file("$scriptpath/sorttv.conf");

#we declare all the possible options through command line
#each option can have multiple variables (|) and can be used like
# "-opt" or "-opt=value" or "opt=value" or "opt value" or "-opt value"
GetOptions(@optionlist);


#we stop the script and show the help if help or man option was used
showhelp(1) if $help or $man;

process_args(@ARGV);
if(!defined($sortdir) || !defined($tvdir)) {
    out("warn", "Incorrect usage or configuration (missing sort or sort-to directories)\n");
    out("warn", "run 'perl sorttv.pl --help' for more information about how to use SortTV");
    exit;
}

# if uses thetvdb, set it up
if($renameformat =~ /\[EP_NAME\d]/i || $fetchimages ne "FALSE" 
  || $lookupseasonep ne "FALSE" || $lookupseasonep ne "FALSE") {
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

if ($createundoscript)
{
    unlink($undoscriptname);
    if (copy("undoscript.pl.in", $undoscriptname))
    {
        $undoscript = FileHandle->new($undoscriptname, "a") or out("warn", "WARN: Could not open $undoscriptname for writing: $!\n");
    }
    else
    { 
        out("warn", "WARN: Could not create undo script $undoscriptname: $!\n");
    }
}


display_info();

sort_directory($sortdir);

if($xbmcwebserver && $newshows) {
	sleep(4);
	# update xbmc video library
	get "http://$xbmcwebserver/xbmcCmds/xbmcHttp?command=ExecBuiltIn(updatelibrary(video))";
	# notification of update
	get "http://$xbmcwebserver/xbmcCmds/xbmcHttp?command=ExecBuiltIn(Notification(,NEW EPISODES NOW AVAILABLE TO WATCH\n$newshows, 7000))";
}

$log->close if(defined $log);
$undoscript->close if($undoscript);

exit;


sub sort_directory {
	my ($sortd) = @_;
	# escape special characters from  bsd_glob
	my $escapedsortd = $sortd;
	$escapedsortd =~ s/(\[|]|\{|}|-|~)/\\$1/g;

	if($extractrar eq "TRUE") {
		extract_archives($escapedsortd, $sortd);
	}

	FILE: foreach my $file (bsd_glob($escapedsortd.'*')) {
		$showname = "";
		my $nonep = "FALSE";
		my $dirsandfile = $file;
		$dirsandfile =~ s/\Q$sortdir\E//;
		my $filename = filename($file);

		# check white and black lists
		if(check_lists(filename($file)) eq "NEXT") {
			next FILE;
		}
		# check size
		if (check_filesize($file) eq "NEXT") {
			next FILE;
		}
		# check age
		if ($sortolderthandays && -M $file < $sortolderthandays) {
			out("std", "SKIP: $file is newer than $sortolderthandays days old.\n");
			next FILE;
		}

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
		# Regex for tv show season directory
		} elsif($treatdir eq "AS_FILES_TO_SORT" && -d $file && $file =~ /.*\/(.*)(?:Season|Series|$seasontitle)\D?0*(\d+).*/i && $1) {
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
		# Regex for tv show episode: S01E01 or 1x1 or 1 x 1 or 101 or [1x1] etc
		} elsif($filename =~ /(.*?)(?:\.|\s|-|_|\[)+[Ss]0*(\d+)(?:\.|\s|-|_)*[Ee]0*(\d+).*/
		|| $filename =~ /(.*)(?:\.|\s|-|_)+\[?0*(\d+)\s*[xX-]\s*0*(\d+).*/
		|| $filename =~ /(.*)(?:\.|\s|-|_)+0*(\d)(\d{2})(?:\.|\s).*/
		# "Show/Season 1/1.avi" or "Show Season 1/101.avi" or "Show/Season 1/1x1.avi" or "Show Series 1 Episode 1.avi" etc
		|| $dirsandfile =~ /(.*?)(?:\.|\s|\/|\\|-|\1)*(?:Season|Series|\Q$seasontitle\E)\D?0*(\d+)(?:\.|\s|\/|\\|-|\1)+\[?0*\d+\s*[xX-]\s*0*(\d+).*/i
		|| $dirsandfile =~ /(.*?)(?:\.|\s|\/|\\|-|\1)*(?:Season|Series|\Q$seasontitle\E)\D?0*(\d+)(?:\.|\s|\/|\\|-|\1)+\d?(?:[ .-]*Episode[ .-]*)?0*(\d{1,2}).*/i
		|| ($matchtype eq "LIBERAL" && filename($file) =~ /(.*)(?:\.|\s|-|_)0*(\d+)\D*0*(\d+).*/)) {
			$pureshowname = $1;
			$showname = fixtitle($pureshowname);
			if($seasondoubledigit eq "TRUE") {
				$series = sprintf("%02d", $2);
			} else {
				$series = $2;
			}
			$episode = $3;
			if($pureshowname ne "") {
				if($tvdir !~ /^KEEP_IN_SAME_DIRECTORIES/) {
					if(move_episode($pureshowname, $showname, $series, $episode, $file) eq $REDO_FILE) {
						redo FILE;
					}
				} else {
					rename_episode($pureshowname, $series, $episode, $file);
				}
			}
		# match "Show - Episode title.avi" or "Show - [AirDate].avi"
		} elsif( (($treatdir eq "AS_FILES_TO_SORT" && -d $file) || -f $file) && $lookupseasonep eq "TRUE" && (filename($file) =~ /(.*)(?:\.|\s)(\d{4}[-.]\d{1,2}[-.]\d{1,2}).*/
		|| filename($file) =~ /(.*)-(.*)(?:\..*)/)) {
			$pureshowname = $1;
			$showname = fixtitle($pureshowname);
			my $episodetitle = fixdate($2);
			$series = "";
			$episode = "";
			# calls fetchseasonep to try and find season and episode numbers: returns array [0] = Season [1] = Episode
			my @foundseasonep = fetchseasonep(resolve_show_name($pureshowname), $episodetitle);
			if(exists $foundseasonep[1]) {
				$series = $foundseasonep[0];
				$episode = $foundseasonep[1];
			}
			if($series ne "" && $episode ne "") {
				if($seasondoubledigit eq "TRUE" && $series =~ /\d+/) {
					$series = sprintf("%02d", $series);
				}
				if($tvdir !~ /^KEEP_IN_SAME_DIRECTORIES/) {
					if(move_episode($pureshowname, $showname, $series, $episode, $file) eq $REDO_FILE) {
						redo FILE;
					}
				} else {
					rename_episode($pureshowname, $series, $episode, $file);
				}
			} else {
				#if we can't find a matching show and episode we assume this is not an episode file
				$nonep = "TRUE";
			}
		} else {
			$nonep = "TRUE";
		}
		# move non-episodes
		if($nonep eq "TRUE" && defined $nonepisodedir && $tvdir ne "KEEP_IN_SAME_DIRECTORIES") {
			my $newname = $file;
			$newname =~ s/\Q$sortdir\E//;
			if($flattennonepisodefiles eq "FALSE") {
				my $dirs = path($newname);
				my $filename = filename($newname);
				if(! -d $file && ! -e $nonepisodedir . $dirs) {
					# recursively creates the dir structure
					make_path($nonepisodedir . $dirs);
				}
				$newname = $dirs . $filename;
			} else { # flatten
				$newname = escape_myfilename($newname);
			}
			out("std", "MOVING NON-EPISODE: $file to $nonepisodedir$newname\n");
			if(-d $file) {
				dirmove($file, $nonepisodedir . $newname) or out("warn", "WARN: File $file cannot be copied to $nonepisodedir. : $!");
			} else {
				move($file, $nonepisodedir . $newname) or out("warn", "WARN: File $file cannot be copied to $nonepisodedir. : $!");
			}
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
			$in =~ s/\\/\//g;
			if($in =~ /^\s*#/ || $in =~ /^\s*$/) {
				# ignores comments and whitespace
			} elsif($in =~ /([^:]+?):(.+)/) {
			    
				GetOptionsFromString("--$1=\"$2\"", @optionlist);
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
	Alternatively set this to "KEEP_IN_SAME_DIRECTORIES" for a recursive renaming of files in directory-to-sort

--non-episode-dir:dir
	Where to put things that are not episodes
	If this is supplied then files and directories that SortTV does not believe are episodes will be moved here
	If not specified, non-episodes are not moved

--whitelist:pattern
	Only copy if the file matches one of these patterns
	Uses shell-like simple pattern matches (eg *.avi)
	This argument can be repeated to add more rules

--blacklist:pattern
	Don't copy if the file matches one of these patterns
	Uses shell-like simple pattern matches (eg *.avi)
	This argument can be repeated to add more rules

--filesize-range:pattern
	Only copy files which fall within these filesize ranges.
	Examples for the pattern include 345MB-355MB or 1.05GB-1.15GB

--sort-only-older-than-days:[DAYS]
	Sort only files or directories that are older than this number of days.  
	If not specified or zero, sort everything.

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

--fetch-show-title:[TRUE|FALSE]
	Fetch show titles from thetvdb.com (for proper formatting)
	If not specified, TRUE

--rename-episodes:[TRUE|FALSE]
	Rename episodes to a new format when moving
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

--match-files-based-on-tvdb-lookups:[TRUE|FALSE]
	Attempt to sort files that are named after the episode title or air date.
	For example, "My show - My episode title.avi" or "My show - 2010-12-12.avi"
	 could become "My Show - S01E01 - My episode title.avi"
	Attempts to lookup the season and episode number based on the episodes in thetvdb.com database.
	Since this involves downloading the list of episodes from the Internet, this will cause a slower sort.
	If not specified, TRUE

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
	Substitutes names equal to NAME1 for NAME2
	This argument can be repeated to add multiple rules for substitution

--tvdb-id-substitute:NAME1-->TVDB ID
	Substitutes names equal to NAME1 for TVDB ID for lookups
	This argument can be repeated to add multiple rules for substitution

--force-windows-compatible-filenames:[TRUE|FALSE]
	Forces MSWindows compatible file names, even when run on other platforms such as Linux
	This may be helpful if you are writing to a Windows share from a Linux system
	If not specified, TRUE

--lookup-language:[en|...]
	Set language for thetvdb lookups, this effects episode titles etc
	Valid values include: it, zh, es, hu, nl, pl, sl, da, de, el, he, sv, eng, fi, no, fr, ru, cs, en, ja, hr, tr, ko, pt
	If not specified, en (English)

--flatten-non-eps:[TRUE|FALSE]
	Should non-episode files loose their directory structure?
	This option only has an effect if a non-episode directory was specified.
	If set to TRUE, they will be renamed after directory they were in.
	Otherwise they keep their directory structure in the new non-episode-directory location.
	If not specified, FALSE

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

--if-file-exists:[SKIP|OVERWRITE]
	What to do if a file already exists in the destination
	If not specified, SKIP

--extract-compressed-before-sorting:[TRUE|FALSE]
	Extracts the contents of archives (.zip, .rar) into the directory-to-sort while sorting
	If "rar" and "unzip" programs are available they are used.
	If not specified, TRUE

--no-network
	Disables all the network enabled features such as:
		Disables notifying xbmc
		Disables tvdb title formatting
		Disables fetching images
		Disables looking up files named "Show - EpTitle.ext" or by airdate
		Changes rename format (if applicable) to not include episode titles

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

# replaces ".", "_" and removes "the" and ","
# removes numbers and spaces
# removes the dir path
sub fixtitle {
	my ($title) = @_;
	$title =~ s/,|\.the\.|\bthe\b//ig;
	$title =~ s/\.and\.|\band\b//ig;
	$title =~ s/&|\+|'|_//ig;
	$title =~ s/(.*\/)(.*)/$2/;
	$title = remdot($title);
	$title =~ s/\d|\s|\(|\)//ig;
	return $title;
}

# format a date to YYYY-MM-DD for air date look up
# if not a date send it to fixtitle
sub fixdate {
	my ($title) = @_;
	if($title =~ /(\d{4})[-.](\d{1,2})[-.](\d{1,2})/) {
		my $month = sprintf("%02d", $2);
		my $day = sprintf("%02d", $3);
		return $1."-".$month."-".$day;
	} else {
		return fixtitle($title);
	}
}

# substitutes show names as configured
sub substitute_name {
	my ($from) = @_;
	foreach my $substitute (keys %showrenames){
        if(fixtitle($from) =~ /^\Q$substitute\E$/i) {
                return $showrenames{$substitute};
        }
    }
	# if no matches, returns unchanged
	return $from;
}

# resolves a raw text string to a show name
# starts by checking if there is a literal rule substituting the string as is
# then removes dots dashes etc, and tries a substution again
# then checks if there is a tvdbid, if so renames using database
sub resolve_show_name {
	my ($title) = @_;
	return tvdb_title(substitute_name(remdot($title)));
}

# Use tvdb IDs to lookup shows
# returns the ID if available, or an empty string
sub substitute_tvdb_id {
	my ($from) = @_;	
	foreach my $substitute (keys %showtvdbids){
        if(fixtitle($from) =~ /^\Q$substitute\E$/i) {
                return $showtvdbids{$substitute};
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

# removes filename
sub path {
	my ($title) = @_;
	if($title =~ s/(.*)(?:\/|\\)(.*)/$1/) {
		return $title."/";
	} else {
		return "";
	}
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

# turns a simple wildcard pattern into a regex
# this is from the Perl Cookbook
sub glob2pat {
	my $globstr = shift;
	my %patmap = (
		'*' => '.*',
		'?' => '.',
		'[' => '[',
		']' => ']',);
	$globstr =~ s{(.)} { $patmap{$1} || "\Q$1" }ge;
	return '^' . $globstr . '$';
}

# checks white and black list
# returns "OK" or "NEXT"
sub check_lists {
	my ($file) = @_;
	# check whitelist, skip if doesn't match one
	my $found = "FALSE";
	foreach my $white (@whitelist) {
		if($file =~ /$white/) {
			$found = "TRUE";
		}
	}
	if($found eq "FALSE" && scalar(@whitelist)) {
		out("std", "SKIP: Doesn't match whitelist: $file\n");
		return "NEXT";
	}
	# check blacklist, skip if it matches any
	foreach my $black (@blacklist) {
		if($file =~ /$black/) {
			out("std", "SKIP: Matches blacklist: $file\n");
			return "NEXT";
		}
	}
	return "OK";
}

sub check_filesize {
	my ($file) = @_;
	my $filesize = (-s $file) / 1024 / 1024;

	# only check size if configured, and it is a regular file
	if (! -f $file || @sizerange == 0) {
		return "OK";
	}

	# Loop through the size ranges passed in via the config file
	foreach my $size (@sizerange) {
		if ($size =~ /(.*)-(.*)/) {
			my $minfilesize = $1;
			my $maxfilesize = $2;

			# Check the filesize
			if ($minfilesize < $filesize && $filesize < $maxfilesize) {
				return "OK";
			}
		}
	}

	# Skip the file as it didn't fall within a specified filesize range
	my $filename = filename($file);
	out("std", "SKIP: Doesn't fit the filesize requirements: $filename\n");
	return "NEXT";
}

sub num_found_in_list {
	my ($find, @list) = @_;
	foreach (@list) {
		if($find == $_) {
			return "TRUE";
		}
	}
	return "FALSE";
}

# extract .rar, .zip files
# tries to use these programs: rar, unrar, unzip, 7zip
# if 7zip is used it will always overwrite existing files
sub extract_archives {
	my ($escapedsortd, $sortd) = @_;
	my $over = "";
	my @errors = (-1, 32512);
	foreach my $arfile (bsd_glob($escapedsortd.'*.{rar,zip,7z,gz,bz2}')) {
		if($arfile =~ /.*\.rar$/) {
			if($ifexists eq "OVERWRITE") {
				$over = "+";
			} else {
				$over = "-";
			}

			if(num_found_in_list(system("rar e -o$over '$arfile' '$sortd'"), @errors) eq "FALSE") {
				out("std", "RAR: extracting $arfile into $sortd\n");
			} elsif(num_found_in_list(system("unrar e -o$over '$arfile' '$sortd'"), @errors) eq "FALSE") {
				out("std", "UNRAR: extracting $arfile into $sortd\n");
			} elsif(num_found_in_list(system("7z e -y '$arfile' -o'$sortd'"), @errors) eq "FALSE") {
				out("std", "7ZIP: extracting $arfile into $sortd\n");
			} elsif(num_found_in_list(system("7za e -y '$arfile' -o'$sortd'"), @errors) eq "FALSE") {
				out("std", "7ZIP: extracting $arfile into $sortd\n");
			} elsif(num_found_in_list(system("C:\\Program Files\\7-Zip\\7z.exe e -y '$arfile' -o'$sortd'"), @errors) eq "FALSE") {
				out("std", "7ZIP: extracting $arfile into $sortd\n");
			} else {
				out("std", "WARN: the rar / 7zip program could not be found, not decompressing $arfile\n");
			}
		} elsif($arfile =~ /.*\.zip$/) {
			if($ifexists eq "OVERWRITE") {
				$over = "-o";
			} else {
				$over = "-n";
			}

			if(num_found_in_list(system("unzip $over '$arfile' -d '$sortd'"), @errors) eq "FALSE") {
				out("std", "RAR: extracting $arfile into $sortd\n");
			} elsif(num_found_in_list(system("7z e -y '$arfile' -o'$sortd'"), @errors) eq "FALSE") {
				out("std", "7ZIP: extracting $arfile into $sortd\n");
			} elsif(num_found_in_list(system("7za e -y '$arfile' -o'$sortd'"), @errors) eq "FALSE") {
				out("std", "7ZIP: extracting $arfile into $sortd\n");
			} elsif(num_found_in_list(system("C:\\Program Files\\7-Zip\\7z.exe e -y '$arfile' -o'$sortd'"), @errors) eq "FALSE") {
				out("std", "7ZIP: extracting $arfile into $sortd\n");
			} else {
				out("std", "WARN: the unzip / 7zip program could not be found, not decompressing $arfile\n");
			}
		} elsif($arfile =~ /.*\.(?:7z|gz|bz2)$/) {
			if(num_found_in_list(system("7z e -y '$arfile' -o'$sortd'"), @errors) eq "FALSE") {
				out("std", "7ZIP: extracting $arfile into $sortd\n");
			} elsif(num_found_in_list(system("7za e -y '$arfile' -o'$sortd'"), @errors) eq "FALSE") {
				out("std", "7ZIP: extracting $arfile into $sortd\n");
			} elsif(num_found_in_list(system("C:\\Program Files\\7-Zip\\7z.exe e -y '$arfile' -o'$sortd'"), @errors) eq "FALSE") {
				out("std", "7ZIP: extracting $arfile into $sortd\n");
			} else {
				out("std", "WARN: the 7zip program could not be found, not decompressing $arfile\n");
			}
		}
	}
}

sub display_info {
	my ($second, $minute, $hour, $dayofmonth, $month, $yearoffset) = localtime();
	my $year = 1900 + $yearoffset;
	my $thetime = "$hour:$minute:$second, $dayofmonth-$month-$year";
	out("std", "$thetime\n"); 
	out("std", "Sorting $sortdir into $tvdir\n"); 
}

sub rename_episode {
	my ($pureshowname, $series, $episode, $file) = @_;

	out("verbose", "INFO: trying to rename $pureshowname season $series episode $episode\n");
	# test if it matches a simple version, or a substituted version of the file to move
	move_an_ep($file, path($file), path($file), $series, $episode);
	return 0;
}

sub move_episode {
	my ($pureshowname, $showname, $series, $episode, $file) = @_;

	out("verbose", "INFO: trying to move $pureshowname season $series episode $episode\n");
	SHOW: foreach my $show (bsd_glob($tvdir.'*')) {
		# test if it matches a simple version, or a substituted version of the file to move
		my $subshowname = fixtitle(escape_myfilename(resolve_show_name($pureshowname)));
		if(fixtitle(filename($show)) =~ /^\Q$showname\E$/i || fixtitle(escape_myfilename(filename($show))) =~ /^\Q$subshowname\E$/i) {
			out("verbose", "INFO: found a matching show:\n\t$show\n");
			my $s = $show.'/*';
			my @g=bsd_glob($show);
			foreach my $season (bsd_glob($show.'/*')) {
				if(-d $season.'/' && $season =~ /(?:Season|Series|$seasontitle)?\s?0*(\d+)$/i && $1 == $series) {
					out("verbose", "INFO: found a matching season:\n\t$season\n");
					move_an_ep($file, $season, $show, $series, $episode);
					# next FILE;
					return 0;
				}
			}
			# didn't find a matching season, make DIR
			out("std", "INFO: making season directory: $show/$seasontitle$series\n");
			my $newpath = "$show/$seasontitle$series";
			if(mkdir($newpath, 0777)) {
				fetchseasonimages(resolve_show_name($pureshowname), $show, $series, $newpath) if $fetchimages ne "FALSE";
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
		my $newshowdir = $tvdir .escape_myfilename(resolve_show_name($pureshowname));
		out("std", "INFO: making show directory: $newshowdir\n");
		if(mkdir($newshowdir, 0777)) {
			fetchshowimages(resolve_show_name($pureshowname), $newshowdir) if $fetchimages ne "FALSE";
			# try again now that the dir exists
			# redo FILE;
			return $REDO_FILE;
		} else {
			out("warn", "WARN: Could not create show dir: $newshowdir:$!\n");
			# next FILE;
			return 0;
		}
	} else {
		out("verbose", "SKIP: Show directory does not exist: " . $tvdir . escape_myfilename(resolve_show_name($pureshowname))."\n");
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
	my $epimage = $tvdb->getEpisodeBanner($fetchname, $season, $episode);
	my $newimagepath = "$seasondir/$newfilename";
	$newimagepath =~ s/(.*)(\..*)/$1.tbn/;
	copy ("$scriptpath/.cache/$epimage", $newimagepath) if $epimage && -e "$scriptpath/.cache/$epimage";
}

# lookup episode details based on show name and episode title or air date
sub fetchseasonep {
	my ($show, $eptitle) = @_;
	# make sure we have all the series data in cache
	my $seriesall = $tvdb->getSeries(resolve_show_name($show));
	my @seasonep;
	# get the show name from the hash
	my $showtitle = $seriesall->{'SeriesName'};
	if(defined $showtitle) {
		if($eptitle =~ /\d{4}-\d{2}-\d{2}/){
			# get episode details from show title and air date
			my $epdetails = $tvdb->getEpisodeByAirDate($showtitle, $eptitle);
			if(defined($epdetails)) {
				$seasonep[0] = $epdetails->[0]->{'SeasonNumber'};
				$seasonep[1] = $epdetails->[0]->{'EpisodeNumber'};
				#temporary solution to episode number over 49
				$forceeptitle = $epdetails->[0]->{'EpisodeName'} if $seasonep[1] >= 50;
				# pass back the Season Number and Episode Number in an array
				return @seasonep;
			}
		} else {
			my $season = 1;
			# make sure you know what season to stop at
			my $maxseasons = $tvdb->getMaxSeason($seriesall->{'SeriesName'});
			# work through the seasons
			while($season <= $maxseasons) {
				my @epid = $tvdb->getSeason($showtitle, $season);
				my $spot = 1;
				# process each episode id
				while($epid[0]) {
					if(defined($epid[0][$spot])) {
						my $epdetails = $tvdb->getEpisodeId($epid[0][$spot]);
						if(defined($epdetails)) {
							# compare the Episode to the one in the search
							if(fixtitle($epdetails->{'EpisodeName'}) =~ /^\Q$eptitle\E$/) {
								$seasonep[0] = $epdetails->{'SeasonNumber'};
								$seasonep[1] = $epdetails->{'EpisodeNumber'};
								#temporary solution to episode number over 49
								$forceeptitle = $epdetails->{'EpisodeName'} if $seasonep[1] >= 50;
								# pass back the Season Number and Episode Number in an array
								return @seasonep;
							}
						}
						$spot++;
					} else {
						last;
					}
				}
				$season++;
			}
		}
	} else {
		out("std", "WARN: Failed to get " . $show . " series information on the tvdb.com.\n");
	}
	return @seasonep;
}

# if the option is enabled, looks up the show title using the substitute_tvdb_id then the filename
# returns the title with the format from thetvdb.com, or if not found the original string
sub tvdb_title {
	my ($filetitle) = @_;
	# if the show name is only special chars then leave as is
	if (!$filetitle) {
		$filetitle = $pureshowname;
	}
	if($tvdbrename eq "TRUE") {
		my $id_sub = substitute_tvdb_id($filetitle);
		if($id_sub =~ /^[+-]?\d+$/) {
			my $newname = $tvdb->getSeriesName($id_sub);
			if($newname) {
				return $newname;
			}
		}
		my $retval;
		$retval = $tvdb->getSeries($filetitle);
		# if it finds one return it
		if(defined($retval)) {
			return $retval->{'SeriesName'};
		}		
	}
	return $filetitle;
}

sub move_an_ep {
	my($file, $season, $show, $series, $episode) = @_;
	my $newfilename = filename($file);
	my $newpath;
	my $sendxbmcnotifications = $xbmcwebserver;
	
	my $ep1 = sprintf("S%02dE%02d", $series, $episode);
	if($rename eq "TRUE") {
		my $ext = my $eptitle = "";
		unless(-d $file) {
			$ext = $file;
			$ext =~ s/(.*\.)(.*)/\.$2/;
		}
		if($renameformat =~ /\[EP_NAME(\d)]/i) {
			out("verbose", "INFO: Fetching episode title for ", resolve_show_name($pureshowname), " Season $series Episode $episode.\n");
			my $name;
			# HACK - setConf maxEpisode apparently doesn't register, temporary fix
			if(defined($forceeptitle)&& $forceeptitle ne "") {
				# set it if you had to force a ep title
				$name = $forceeptitle;
				# forget so we can be fresh for the next file
				$forceeptitle = "";	
			} else {
				$name = $tvdb->getEpisodeName(substitute_tvdb_id(resolve_show_name($pureshowname)), $series, $episode);
			}
			my $format = $1;
			if($name) {
				$name =~ s/\s+$//;		
				# support for utf8 characters in episode names
				require Encode;
				$eptitle = " - " . Encode::decode_utf8($name) if $format == 1;
				$eptitle = "." . Encode::decode_utf8($name) if $format == 2;
			} else {
				out("warn", "WARN: Could not get episode title for ", resolve_show_name($pureshowname), " Season $series Episode $episode.\n");
			}
		}
		my $sname = resolve_show_name($pureshowname);
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
	$newpath = $season;
	$newpath .= '/' if($newpath !~ /\/$/);
	$newpath .= $newfilename;
	if(-e $newpath) {
		if(filename($file) =~ /repack|proper/i) {
			# still overwrites if copying, but doesn't output a message unless verbose
			if($verbose eq "TRUE" || ($sortby ne "COPY" && $sortby ne "PLACE-SYMLINK")) {
				out("warn", "OVERWRITE: Repack/proper version.\n");
				out("std", "$sortby: sorting $file to ", $newpath, "\n");
			} else {
				$sendxbmcnotifications = "";
			}
		} elsif($ifexists eq "OVERWRITE") {
			out("warn", "OVERWRITE: Existing file.\n");
			out("std", "$sortby: sorting $file to ", $newpath, "\n");
		} elsif($ifexists eq "SKIP") {
			if($verbose eq "TRUE" || ($sortby ne "COPY" && $sortby ne "PLACE-SYMLINK")) {
				out("warn", "SKIP: File $newpath already exists, skipping.\n");
			}
			return;
		}
	} else {
		out("std", "$sortby: sorting $file to ", $newpath, "\n");
	}
	if($sortby eq "MOVE" || $sortby eq "MOVE-AND-LEAVE-SYMLINK-BEHIND") {
		if(-d $file) {
			dirmove($file, $newpath) or out("warn", "File $file cannot be moved to $newpath. : $!");
		} else {
		    move($file, $newpath) or out("warn", "File $file cannot be moved to $newpath. : $!");
		}
	} elsif($sortby eq "COPY") {
		if(-d $file) {
			dircopy($file, $newpath) or out("warn", "File $file cannot be copied to $newpath. : $!");
		} else {
			copy($file, $newpath) or out("warn", "File $file cannot be copied to $newpath. : $!");
		}
	} elsif($sortby eq "PLACE-SYMLINK") {
		symlink($file, $newpath) or out("warn", "File $file cannot be symlinked to $newpath. : $!");
	}
	# have moved now link
	if($sortby eq "MOVE-AND-LEAVE-SYMLINK-BEHIND") {
		symlink($newpath, $file) or out("warn", "File $newpath cannot be symlinked to $file. : $!");
	}
	# if the episode was moved (or already existed)
	if(-e $newpath) {
	    
        add_undo($sortby, $file, $newpath);
	    
		if ($fetchimages ne "FALSE") {
			fetchepisodeimage(resolve_show_name($pureshowname), $show, $series, $season, $episode, $newfilename);
		}
		if($sendxbmcnotifications) {
			$new = resolve_show_name($pureshowname) . " $ep1";
			my $retval = get "http://$xbmcwebserver/xbmcCmds/xbmcHttp?command=ExecBuiltIn(Notification(NEW EPISODE, $new, 7000))";
			if(undef($retval)) {
				out("warn", "WARN: Could not connect to xbmc webserver.\nRECOMMENDATION: If you do not use this feature you should disable it in the configuration file.\n");
				$xbmcwebserver = "";
			}
			$newshows .= "$new\n";
		}
	}
}

sub add_undo {
    #lets undo the operation that created $newpath
    my($operation, $file, $newpath) = @_;
    
    return if (not $undoscript or not -e $newpath);
    
    print $undoscript "\nif (user_asked_for_undo(\"Do you want to undo action applied on $file ,\\n which created $file? (y/n)\")) {\n";
    if($operation eq "MOVE" || $operation eq "MOVE-AND-LEAVE-SYMLINK-BEHIND") {
        print $undoscript "rmove(\"$newpath\", \"$file\") or out(\"warn\", \"File $file cannot be moved to $newpath. : $!\");";
    } elsif($operation eq "COPY") {
        if(-d $newpath) {
            print $undoscript "rmtree(\"$newpath\") or out(\"warn\", \"File $newpath cannot be deleted. : $!\");";
        } else {
            print $undoscript "unlink(\"$newpath\") or out(\"warn\", \"File $newpath cannot be deleted. : $!\");";
        }
    } elsif($operation eq "PLACE-SYMLINK") {
            print $undoscript "unlink\"$newpath\") or out(\"warn\", \"File $newpath cannot be deleted. : $!\");";
    }
    print $undoscript "}\n";
}

sub move_a_season {
	my($file, $show, $series) = @_;
	my $newpath = $show."/".escape_myfilename("$seasontitle$series", "-");
	if(-e $newpath) {
		out("warn", "SKIP: File $newpath already exists, skipping.\n") unless($sortby eq "COPY" || $sortby eq "PLACE-SYMLINK");
		return;
	}
	out("std", "$sortby SEASON: $file to $newpath\n");
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
				get "http://$xbmcwebserver/xbmcCmds/xbmcHttp?command=ExecBuiltIn(Notification(NEW EPISODE, $new, 7000))";
				$newshows .= "$new\n";
			}
			return 0;
		}
	}
	if($needshowexist ne "TRUE") {
		# if we are here then we couldn't find a matching show, make DIR
		my $newshowdir = $tvdir .escape_myfilename(resolve_show_name($pureshowname));
		out("std", "INFO: making show directory: $newshowdir\n");
		if(mkdir($newshowdir, 0777)) {
			fetchshowimages(resolve_show_name($pureshowname), $newshowdir) if $fetchimages ne "FALSE";
			# try again now that the dir exists
			# redo FILE;
			return $REDO_FILE;
		} else {
			out("warn", "WARN: Could not create show dir: $newshowdir:$!\n");
			# next FILE;
			return 0;
		}
	} else {
		out("verbose", "SKIP: Show directory does not exist: " . $tvdir . escape_myfilename(resolve_show_name($pureshowname))."\n");
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
	} elsif($type eq "std") {
		print @msg;
		print $log @msg if(defined $log);
	} elsif($type eq "warn") {
		warn @msg;
		print $log @msg if(defined $log);
	}
}
