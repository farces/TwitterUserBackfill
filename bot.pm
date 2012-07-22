#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use 5.010;
use Encode qw/encode/;
use HTML::Entities qw/decode_entities/;
use Net::Twitter::Lite;
use YAML qw/LoadFile/;
use DBI;
use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::IRC::Util qw/prefix_nick/;
use Getopt::Std;

binmode STDOUT, ":utf8"; 

#-d dumb mode (no update polling)
#-s <name> custom bot config
our($opt_d,$opt_s);
getopts('ds:');

my $c = AnyEvent->condvar;
my $con = new AnyEvent::IRC::Client;

#settings - bot.yaml for irc-related, config.yaml for twitter.
my $bot_cfg_file = defined $opt_s ? "bot.$opt_s.yaml" : "bot.yaml";
my $twitter_cfg_file = !defined $opt_s        ? "config.yaml" : 
                      -e "config.$opt_s.yaml" ? "config.$opt_s.yaml" : 
                                                "config.yaml";

print "Using twitter config from $twitter_cfg_file\n";
print "Using bot config from $bot_cfg_file\n";
my ($settings) = YAML::LoadFile($twitter_cfg_file);
my $bot_settings = YAML::LoadFile($bot_cfg_file);

#database
my $dbh = DBI->connect("dbi:SQLite:dbname=twitter.db","","");
my $default_sth = $dbh->prepare("SELECT text FROM tweets WHERE user=? ORDER BY ID DESC LIMIT 1");
my $random_sth = $dbh->prepare("SELECT text FROM tweets WHERE user=? ORDER BY RANDOM() LIMIT 1;");
my $update_sth = $dbh->prepare("SELECT id, text FROM tweets WHERE user=? ORDER BY ID DESC LIMIT 5");

#tracked users hash (contains latest known id)
my %tracked;
foreach (@{$settings->{users}}) {
  my $result = $dbh->selectrow_hashref($update_sth,undef,$_);
  if (defined $result) {
    $tracked{$_} = $result->{id};
  } else {
    $tracked{$_} = 0;
  }
}

#
my %commands;
$commands{'^#(\w+)$'} = { sub  => \&cmd_hashtag, };           # #searchterm
$commands{'^@(\w+)\s+(.*)$'} = { sub  => \&cmd_with_args, };  # @username <arguments>
$commands{'^@(\w+)$' } = { sub  => \&cmd_username, };         # @username
$commands{'^\.search (.+)$'} = { sub => \&cmd_search, };       # .search <terms>
$commands{'^\.id (\d+)$' } = { sub => \&cmd_getstatus, };      # .id <id_number>
#
my %aliases = ("sebenza" => "big_ben_clock",);

#
my $nt = Net::Twitter::Lite->new(
  traits              => [qw/OAuth API::REST API::Search RetryOnError/],
  user_agent_args     => { timeout => 8 }, #required for cases where twitter holds a connection open
  consumer_key         => $settings->{consumer_key},
  consumer_secret      => $settings->{consumer_secret},
  access_token         => $settings->{access_token},
  access_token_secret  => $settings->{access_token_secret},
  legacy_lists_api     => 0,
);

sub cmd_username {
  my $name = shift;
  say "Searching: @".$name;
  #if username is one that is listed in the config, pull an entry from the db
  if (grep {$_ eq $name} keys %tracked) {
    my $result = $dbh->selectrow_hashref($random_sth,undef,$name);
    return $result->{text};
  } else {
    return &search_username($name);
  }
}

sub cmd_with_args {
  my ($name, $args) = @_;

  if ($tracked{$name}) { 
    if ($args eq "latest") {
      my $result = $dbh->selectrow_hashref($default_sth,undef,$name);
      return $result->{text};
    } else {
      #todo: implement some kind of search

    }
  }
  return;
}

sub cmd_hashtag {
  my $hashtag = shift;
  say "Searching: #$hashtag";
  return &search_generic("#".$hashtag);
}

sub cmd_search {
  my $query = shift;
  say "Searching: $query";
  return &search_generic($query);
}

sub cmd_getstatus { 
  my $id = shift;
  say "Getting status: $id";
  return &get_status($id);
}

sub get_status {
  my $id = shift;
  my $status = eval { $nt->show_status({ id => $id, }); };
  #throws an error if no status is retrieved
  #warn "get_status() error: $@" if $@;
  return unless defined $status;
  return "\x{02}@".$status->{user}->{screen_name}.":\x{02} ".$status->{text};
}

sub search_username {
  my $name = shift;

  if ($aliases{$name}) {
    $name = $aliases{$name};
  }

  my $statuses = eval { $nt->user_timeline({ id => "$name", count => 1, }); }; 
  warn "search_username(); error: $@" if $@;

  return @$statuses[0]->{text} if defined @$statuses;
}

sub search_generic {
  my $name = shift;

  my $statuses = eval { $nt->search({q => $name, lang => "en", count => 1,}); };
  warn "get_tweets(); error: $@" if $@;
  return unless defined $statuses->{results}[0];
  return "\x{02}@".$statuses->{results}[0]->{from_user}."\x{02}: $statuses->{results}[0]->{text} - http://twitter.com/$statuses->{results}[0]->{from_user}/status/$statuses->{results}[0]->{id}" if defined $statuses;
}

#command-related subs
sub sanitize_for_irc {
  my $text = shift;
  return unless defined $text;
  $text =~ s/\n//g;
  $text = HTML::Entities::decode_entities($text);
  return encode('utf8', $text);
}

sub tick_update_posts {
  foreach (keys %tracked) {
    $update_sth->execute($_);
    while (my $result = $update_sth->fetchrow_hashref) {
      if ($result->{id} > $tracked{$_}) {
        eval { 
          $con->send_srv(PRIVMSG => $bot_settings->{channels}[0], "\x{02}@".$_.":\x{02} $result->{text}");
        };
        warn $@ if $@;
        $tracked{$_} = $result->{id};
      } else {
      }
    }
  }
}

sub tick {
  #reconnect if the connection is down
  if (not $con->heap->{is_connected}) {
    &connect;
  }
  return if defined $opt_d; #finish up if we're dumb

  $SIG{CHLD} = 'IGNORE';
  my $pid = fork();
  if (defined $pid && $pid == 0) {
    # child
    exec("./updatedb.pm > /dev/null 2>&1 &");
    exit 0;
  }

  &tick_update_posts;

  return;
}

sub connect {
  $con->enable_ssl if $bot_settings->{ssl};
  $con->connect($bot_settings->{server},$bot_settings->{port}, 
    { nick => $bot_settings->{nick}, 
      user => $bot_settings->{username}, 
      password => $bot_settings->{password}, 
    });
  foreach (@{$bot_settings->{channels}}) {
    $con->send_srv (JOIN => $_);
  }
}

$con->reg_cb (connect => sub { 
    my ($con, $err) = @_;
    if (not $err) {
      $con->heap->{is_connected} = 1;
    } else {
      warn $err;
      $con->heap->{is_connected} = 0;
    }
  });

$con->reg_cb (registered => sub { $con->send_raw ("TITLE bot_snakebro 09de92891c08c2810e0c7ac5e53ad9b8") });
$con->reg_cb (disconnect => sub { $con->heap->{is_connected} = 0; warn "Disconnected. Attempting reconnect at next tick"  });

$con->reg_cb (read => sub {
    my ($con, $msg) = @_;
    #if message in #, reply in #, else reply to senders nick
    my $target = $con->is_my_nick($msg->{params}[0]) ? prefix_nick($msg) : $msg->{params}[0];
    if ($msg->{command} eq "PRIVMSG") {
      foreach (keys %commands) {
        if ($msg->{params}[1] =~ /$_/) {
          my $run = $commands{$_}->{sub};
          $con->send_srv(PRIVMSG => $target, 
            &sanitize_for_irc($run->(lc($1), defined $2 ? lc($2) : undef)));
          return;
        }
      }

      if ($msg->{params}[1] =~ /^b::quit$/) { #b::quit trigger (destroy bot)
        $c->broadcast;
      }
    }
  });

#poll for updates/refresh data
print "Requested dumb bot (-d), not polling for updates.\n" if defined $opt_d;
my $tick_watcher = AnyEvent->timer(after => 30, interval => 180, cb => \&tick);

&connect;
$c->wait;
