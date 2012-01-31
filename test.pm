#!/usr/bin/perl
use strict;
use 5.010;
use warnings;
use T_B;

sub my_sub {
    my $status = shift;
    say $status->{text};
}

binmode STDOUT, ":utf8";

my $x = T_B->new(
   consumer_key    => "",
   consumer_secret => "",
   access_token    => "",
   access_token_secret => ""
);
$x->connect();
$x->backfill('hambargler',\&my_sub);
