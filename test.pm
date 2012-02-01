#!/usr/bin/perl
use strict;
use 5.010;
use warnings;
use T_B; #use twitter backfill package

#basic subroutine that just prints out the value of the text field in each status
#this can be changed to do whatever you need with the retrieved data, called once
#per status. see https://dev.twitter.com/docs/api/1/get/statuses/user_timeline for
#a list of available fields.
sub my_sub {
    my $status = shift;
    say $status->{created_at} . " :: " . $status->{text};
}

binmode STDOUT, ":utf8"; #required for STDOUT of some non-english characters

#connect to twitter API
#requires your own Twitter API keys, freely available from the twitter dev site.
my $x = T_B->new(
   consumer_key    => "",
   consumer_secret => "",
   access_token    => "",
   access_token_secret => ""
)->connect();
#$x->connect();
#

#request backfill of tweets for user 'hambargler', with my_sub being called
#to act on each individual status.
$x->backfill('hambargler',\&my_sub);
