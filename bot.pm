#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use 5.010;
use YAML qw/LoadFile/;
use DBD::SQLite;
use Getopt::Std qw/getopts/;
use Socket;
use IO::Handle qw/autoflush/;
use JSON::XS qw/encode_json decode_json/;

#socketpair for parent and chandler to communicate
our ($CHILD,$PARENT);
socketpair($CHILD, $PARENT, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair $!";
$PARENT->autoflush(1);
$CHILD->autoflush(1);

$SIG{CHLD} = 'IGNORE';

binmode STDOUT, ":utf8"; 

#-d dumb mode (no update polling)
#-s <name> custom bot config
our($opt_d,$opt_s);
getopts('ds:');

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

print "Loading tracked users... ";
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
print join(",", keys %tracked)."\n";

#fork child to handle commands
my $pid = fork();
my ($nt, %commands, %aliases);
if (defined $pid && $pid == 0) {
  #this block contains child set-up, including all command-related code and variables
  #to ensure the parent doesn't hold on to any unnecessary data and prevent multiple
  #initialization of net::twitter::lite
  use Net::Twitter::Lite;
  print "Starting command handler\n";
  print "Loading twitter OAuth\n";

  $nt = Net::Twitter::Lite->new(
    traits              => [qw/OAuth API::REST API::Search RetryOnError/],
    user_agent_args     => { timeout => 8 }, #required for cases where twitter holds a connection open
    consumer_key         => $settings->{consumer_key},
    consumer_secret      => $settings->{consumer_secret},
    access_token         => $settings->{access_token},
    access_token_secret  => $settings->{access_token_secret},
    legacy_lists_api     => 0,
  );
  
  print "Loading commands\n";

  #OPCODES:
  #REP: reply to msg
  #NOP: no-op
  #SYS: system command (EXIT, RELOAD, etc.)
  #my %commands;
  $commands{'^#(\w+)$'} = { sub  => \&cmd_hashtag, op => "REP", };           # #searchterm
  $commands{'^@(\w+)\s+(.*)$'} = { sub  => \&cmd_with_args, op => "REP", };  # @username <arguments>
  $commands{'^@(\w+)$' } = { sub  => \&cmd_username, op => "REP", };         # @username
  $commands{'^\.search (.+)$'} = { sub => \&cmd_search, op => "REP", };      # .search <terms>
  $commands{'^\.id (\d+)$' } = { sub => \&cmd_getstatus, op => "REP", };     # .id <id_number>
  $commands{'^\.trends\s*(.*)$' } = { sub => \&cmd_gettrends, op => "REP", };
  $commands{'^\.quit$' } = { sub => sub { return "EXIT" }, op => "SYS", };  # .quit (needs fixing)
  #
  %aliases = ("sebenza" => "big_ben_clock",);

  &chandler;
  print "Chandler exited\n";
  exit 0;
}

#parent only from now on
close $PARENT;
undef $nt; undef %aliases; undef %commands;

use Encode qw/encode/;
use HTML::Entities qw/decode_entities/;
use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::IRC::Util qw/prefix_nick/;

my $c = AnyEvent->condvar;
my $con = new AnyEvent::IRC::Client;

#commands
sub cmd_username {
  my $name = shift;
  say "Searching: @".$name;
  #if username is one that is listed in the config, pull an entry from the db
  if (grep {$_ eq $name} keys %tracked) {
    my $result = $dbh->selectrow_hashref($random_sth,undef,$name);
    return $result->{text};
  } else {
    my $result = &search_username($name);
    return $result if defined $result;
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
  my $result = &search_generic("#".$hashtag);
  return $result if defined $result;
}

sub cmd_gettrends {
  my $woeid = shift;
  $woeid = "23424977" if not $woeid;
  say "Getting trends for WOEID: $woeid";
  my $trends = eval { $nt->trends_location($woeid); };
  warn "cmd_gettrends() error: $@" if $@; 
  return unless defined $trends;
  my @names;
  for (@{@{$trends}[0]->{trends}}) {
    push @names, $_->{name};
  }
  return "\x{02}Trending:\x{02} ".join( ', ', @names ) if scalar(@names);
}

sub cmd_search {
  my $query = shift;
  say "Searching: $query";
  my $result = &search_generic($query);
  return $result if defined $result;
}

sub cmd_getstatus { 
  my $id = shift;
  say "Getting status: $id";
  my $result = &get_status($id);
  return $result if defined $result;
}
#

#unfortunately get_status, search_username and search_generic have to be separate
#as they all access different API portions (show_status, user_timeline and search
#respectively)
#these should return nothing if no result was found
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
  my $r = $statuses->{results}[0];
  return "\x{02}@".$r->{from_user}."\x{02}: $r->{text} - http://twitter.com/$r->{from_user}/status/$r->{id}";
}
#

sub sanitize_for_irc {
  my $text = shift;
  return unless defined $text;
  $text =~ s/\n/ /g;
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

sub chandler {
  print "Chandler loaded\n";
  close $CHILD;
  while (my $msg = <$PARENT>) {
    chomp $msg; my $work = decode_json($msg);
    warn $@ if $@; next if $@;

    foreach (keys %commands) {
      if ($work->{msg} =~ /$_/) {
        my $run = $commands{$_}->{sub};
        #run command, with regexp matches $1 and $2 if defined (allows bare .command handling).
        my $result = $run->(defined $1 ? lc $1 : undef , defined $2 ? lc $2 : undef);
        my $data = { op => $commands{$_}->{op}, payload => { target => $work->{target}, msg => $result },};
        print $PARENT encode_json($data)."\n" if $result;
        last;
      }
    }
  } continue { undef $@; }
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

$con->reg_cb (registered => sub { 
    $con->send_raw ("TITLE bot_snakebro 09de92891c08c2810e0c7ac5e53ad9b8") 
  });
$con->reg_cb (disconnect => sub { 
    $con->heap->{is_connected} = 0; 
    warn "Disconnected. Attempting reconnect at next tick" 
  });

$con->reg_cb (read => sub {
    my ($con, $msg) = @_;
    #if message in #, reply in #, else reply to senders nick
    my $target = $con->is_my_nick($msg->{params}[0]) ? prefix_nick($msg) : $msg->{params}[0];
    if ($msg->{command} eq "PRIVMSG") {
      my $work = {target => $target, msg => $msg->{params}[1], };
      print $CHILD encode_json($work)."\n";
    }
  });

#poll for updates/refresh data
print "Requested dumb bot (-d), not polling for updates.\n" if defined $opt_d;
my $tick_watcher = AnyEvent->timer(after => 30, interval => 180, cb => \&tick);

#watcher to recieve replies from chandler's processing
my $w; $w = AnyEvent->io(fh => \*$CHILD, poll => 'r', cb => sub { 
  my $msg = <$CHILD>;

  #deal with erroneus <$CHILD> read events by just killing the bot
  if (!defined $msg) {
    warn "Chandler crash! Oh dear lord!";
    undef $w;
    $c->broadcast;
    return;
  }

  chomp $msg;
  my $data = decode_json($msg);
  warn $@ if $@;
  return if $@;

  if ($data->{op} eq "REP") {
    $con->send_srv(PRIVMSG => $data->{payload}->{target}, &sanitize_for_irc($data->{payload}->{msg}));
  } elsif ($data->{op} eq "SYS") {
    my $action = $data->{payload}->{msg};
    undef $w if ($action eq "EXIT");
    $c->broadcast if ($action eq "EXIT");
  }
});

&connect;
$c->wait;
