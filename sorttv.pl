#!/usr/bin/perl

# 2010 Z. Cliffe Schreuders
# free software: GPL v2 or later
# 
# sorts tv shows into tvshow/series directories
# if the dirs don't exist they are created
# updates xbmc via the web interface
# unsorted files are moved to a dir if specifed


use File::Copy;
use File::Glob ':glob';
use LWP::Simple;
use warnings;
use strict;

(@ARGV >= 2 && @ARGV <= 4) || die "usage: script.pl dir-to-sort dir-to-sort-to [non-episode-dir [xbmcwebserverhostname:port]\n";

my ($sortdir, $tvdir, $nonepisodedir, $xbmcwebserver) = @ARGV;
my ($showname, $series, $episode, $pureshowname) = "";
my ($newshows, $new);

if($nonepisodedir) {
	$nonepisodedir .= '/' if($nonepisodedir !~ /\/$/);
}

# append a trailing / if it's not there
$sortdir .= '/' if($sortdir !~ /\/$/);
$tvdir .= '/' if($tvdir !~ /\/$/);

display_info();

FILE: foreach my $file (bsd_glob($sortdir.'*')) {
	$showname = "";

	if($file =~ /.*\/(.*)(?:\.|\s)[Ss]?0*([1-9]+)\D0*([1-9]+).*/) {
		$pureshowname = $1;
		$showname = fixtitle($pureshowname);
		$series = $2;
		$episode = $3;
	} elsif(defined $nonepisodedir) {
		print "moving non-episode $file to $nonepisodedir\n";
		move($file, $nonepisodedir . filename($file)) or warn "File $file cannot be copied to $nonepisodedir. : $!";
	}

	if($showname ne "") {
		print "trying to move $pureshowname season $series episode $episode\n";
		SHOW: foreach my $show (bsd_glob($tvdir.'*')) {
			my $simpleshowname = '^'.fixtitle2($showname).'$';
			if(fixtitle($show) =~ /$showname/i || fixtitle2($show) =~ /$simpleshowname/i) {
				print "found a matching show:\n\t$show\n";
				my $s = $show.'/*';
				my @g=bsd_glob($show);
				foreach my $season (bsd_glob($show.'/*')) {
					if(-d $season.'/' && $season =~ /(?:Season|Series)?\s?0*(\d)$/i && $1 == $series) {
						print "found a matching season:\n\t$season\n";
						print "moving $file to ", $season . '/' . filename($file), "\n";
						move($file, $season . '/' . filename($file)) or warn "File $show cannot be copied to $season. : $!";
						if($xbmcwebserver) {
							$new = "$showname season $series episode $episode";
							displayandupdateinfo($new, $xbmcwebserver);
							$newshows .= "$new\n";
						}
						next FILE;
					}
				}
				# didn't find a matching season, make DIR
				print "making directory: $show/Season $series\n";
				unless(mkdir("$show/Season $series", 0777)) {
					warn "Could not create dir: $!\n";
					next FILE;
				}
				redo SHOW; # try again now that the dir exists
			}
		}
		# if we are here then we couldn't find a matching show, make DIR
		print "making directory: " . $tvdir . remdot($pureshowname)."\n";
		unless(mkdir($tvdir . remdot($pureshowname), 0777)) {
			warn "Could not create dir: $!\n";
			next FILE;
		}
		redo FILE; # try again now that the dir exists
	}
}

if($xbmcwebserver && $newshows) {
	sleep(4);
        get "http://$xbmcwebserver/xbmcCmds/xbmcHttp?command=ExecBuiltIn(Notification(,NEW EPISODES NOW AVAILABLE TO WATCH\n$newshows, 7000))";
}

exit;


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

# replaces "." and removes "the" and ","
# removes the dir path
sub fixtitle {
	my ($title) = @_;
	$title =~ s/\./ /ig;
	$title =~ s/,|the//ig;
	$title =~ s/(.*\/)(.*)/$2/;
	return $title;
}

# removes numbers and spaces
sub fixtitle2 {
	my ($title) = @_;
	$title = fixtitle($title);
	$title =~ s/\d|\s//ig;
	return $title;
}

# removes dots
sub remdot {
	my ($title) = @_;
	$title =~ s/\./ /ig;
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
	print "Sorting $sortdir\n"; 
	print "into $tvdir\n"; 
}
