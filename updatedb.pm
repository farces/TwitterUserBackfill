#!/usr/bin/env perl
#Script that can be directly called to update tweets from users specified in config.yaml, backfilling
#any users that haven't had any tweets collected yet. 

use strict;
use 5.010;
use warnings;
use T_B; #use twitter backfill package
use YAML::XS qw/LoadFile/;
use DBI;
use Getopt::Std qw/getopts/;

my $dbh = DBI->connect("dbi:SQLite:dbname=twitter.db","","");

#insert preparation
my $insert_query = "INSERT INTO tweets (id, user, text) VALUES (?, ?, ?)";
my $insert_sth = $dbh->prepare($insert_query);

#example callback that prints the id and text values, and stores data to an sqlite database.
sub my_sub {
    my $status = shift;
    $insert_sth->execute($status->{id},lc $status->{user}->{screen_name}, $status->{text});
    #say $status->{id} . " - " . $status->{text};
}

binmode STDOUT, ":utf8"; #required for STDOUT of some non-english characters

#load twitter config
our($opt_s);
getopts('s:');

my $config = defined $opt_s ? $opt_s : "config.yaml";
my ($settings) = LoadFile($config);

#connect to twitter API
#requires your own Twitter API keys, freely available from the twitter dev site.
#say "Creating T_B instance and connect to Twitter API...";
my $x = T_B->new(
   consumer_key         => $settings->{consumer_key},
   consumer_secret      => $settings->{consumer_secret},
   access_token         => $settings->{access_token},
   access_token_secret  => $settings->{access_token_secret},
   legacy_lists_api     => 0,
   ssl                  => 1,
)->connect();
#

my $query = "SELECT id FROM tweets WHERE user= ? ORDER BY ID DESC LIMIT 1";
my $sth = $dbh->prepare($query);

eval {
  my $friends_list = $x->{twitter_i}->friends_list();
  foreach (@{$friends_list->{users}}) {
    print $_->{screen_name}."\n";
    my $result=$dbh->selectrow_hashref($sth,undef,lc $_->{screen_name});
    if (defined $result) {
      #say "Existing tweets found, requesting latest since $result->{id}.";
      $x->recent(lc $_->{screen_name},\&my_sub, $result->{id});
    } else {
      #say "No existing tweets found, filling all.";
      $x->backfill(lc $_->{screen_name}, \&my_sub);
    }   
  }
};

#cleanup
$sth->finish;
$insert_sth->finish;
$dbh->disconnect;
