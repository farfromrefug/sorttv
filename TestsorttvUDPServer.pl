#!/usr/bin/perl -w
use strict;
use IO::Socket;
my $startsorttvcommand = "CALL_SORTTV:";

my $message = IO::Socket::INET->new(Proto=>"udp",PeerPort=>8887,PeerAddr=>"127.0.0.1") 
  or die "Can't make UDP socket: $@";
$message->send($startsorttvcommand . "test");