#!/usr/bin/perl
use strict;
use 5.010;
use warnings;
use T_B; #use twitter backfill package
use YAML qw/LoadFile/;

#basic subroutine that just prints out the value of the text field in each status
#this can be changed to do whatever you need with the retrieved data, called once
#per status. see https://dev.twitter.com/docs/api/1/get/statuses/user_timeline for
#a list of available fields.
sub my_sub {
    my $status = shift;
    say $status->{created_at} . " :: " . $status->{text};
}

binmode STDOUT, ":utf8"; #required for STDOUT of some non-english characters

#load twitter config
my ($settings) = LoadFile('config.yaml');
say "Using following settings:";
say "consumer key        => $settings->{consumer_key}";
say "consumer secret     => $settings->{consumer_secret}";
say "access token        => $settings->{access_token}";
say "access token secret => $settings->{access_token_secret}";

#connect to twitter API
#requires your own Twitter API keys, freely available from the twitter dev site.
say "Creating T_B instance and connect to Twitter API...";
my $x = T_B->new(
   consumer_key         => $settings->{consumer_key},
   consumer_secret      => $settings->{consumer_secret},
   access_token         => $settings->{access_token},
   access_token_secret  => $settings->{access_token_secret},
   legacy_lists_api     => 0,
)->connect();
#

#request backfill of tweets for user 'hambargler', with my_sub being called
#to act on each individual status.
say "Requesting all Tweets for sample user...";
for (@{$settings->{users}}) {
    $x->backfill($_,\&my_sub);
}
