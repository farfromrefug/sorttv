#!/usr/bin/perl -w

# Server Program
use strict;
use IO::Socket;
use Getopt::Long;
use Pod::Usage;
use Switch;
use File::Basename;

Getopt::Long::Configure('ignore_case');

my($scripName, $scripPath, $suffix) = fileparse(__FILE__);
	print "scripPath $scripPath \n";

my $startsorttvcommand = "CALL_SORTTV:";

my $man = 0;
my $help = 0;

my $port = 8887;

GetOptions (
			 "port|p=i" => \$port,
            "h|help|?" => \$help, man => \$man) or pod2usage(2);

#we stop the script and show the help if help or man option was used
pod2usage(1) if $help;
pod2usage(-exitstatus => 0, -verbose => 2) if $man;			
			

# Create a new socket
my $server = IO::Socket::INET->new(LocalPort=>$port,Proto=>"udp")
  or die "Can't create UDP server: $@";
my ($datagram,$flags);

while ($server->recv($datagram,512,$flags)) 
{
  my $ipaddr = $server->peerhost;
	print "received $datagram from $ipaddr\n";
  if (rindex($datagram, $startsorttvcommand) != -1)
  {
	my $args = $datagram;
	$args =~ s/$startsorttvcommand//;
	system("perl ".$scripPath."sorttv.pl ".$args);
  }
}

__END__

=head1 NAME

 sorttvUDPServer - UDP Server to launch sorttv commands

=head1 SYNOPSIS

 sorttvUDPServer [options]

=head1 OPTIONS

=over 8

=item B<-port|p=int>

set UDP communication port.

=item B<-help>

Print a brief help message and exits.

=item B<-man>

Prints the manual page and exits.

=back

=cut
