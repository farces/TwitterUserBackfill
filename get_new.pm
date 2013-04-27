#!/usr/bin/perl
#Script pulls latest 50 tweets from the bot user's home_timeline, which includes all tweets from
#all dudes that are being followed.
#Does not rely on the T_B.pm backfilling/updating module.

use strict;
use 5.010;
use warnings;
use YAML::XS qw/LoadFile/;
use DBI;
use Net::Twitter::Lite::WithAPIv1_1;
use Getopt::Std qw /getopts/;

my $dbh = DBI->connect("dbi:SQLite:dbname=twitter.db","","");

#insert preparation
my $insert_query = "INSERT INTO tweets (id, user, text) VALUES (?, ?, ?)";
my $insert_sth = $dbh->prepare($insert_query);

#this spams the dickens out of stderr because it just attempts to store all pulled
#data into the table, despite the ID key being duplicate most of the time.
sub store_tweet {
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

my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
   consumer_key         => $settings->{consumer_key},
   consumer_secret      => $settings->{consumer_secret},
   access_token         => $settings->{access_token},
   access_token_secret  => $settings->{access_token_secret}
);


#my $query = "SELECT id FROM tweets WHERE user= ? ORDER BY ID DESC LIMIT 1";
#my $sth = $dbh->prepare($query);
my $latest = $dbh->selectrow_array("SELECT id FROM tweets ORDER BY ID DESC LIMIT 1");
print $latest."\n";

eval {
  my $statuses = $nt->home_timeline({ since_id => $latest, });
  for my $status (@$statuses) {
    &store_tweet( $status );
  }
};

$insert_sth->finish;
$dbh->disconnect;
