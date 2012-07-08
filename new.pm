#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use 5.010;
use HTML::Entities qw/decode_entities/;
use Bot::BasicBot;
use Net::Twitter::Lite;
use YAML qw/LoadFile/;
use DBI;

package TestBot;
use base qw/ Bot::BasicBot /;

#settings
my $bot_cfg_file = defined $ARGV[0] ? "bot.".$ARGV[0].".yaml" : "bot.yaml";
my $twitter_cfg_file = defined $ARGV[0] ? "config.".$ARGV[0].".yaml" : "config.yaml";
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
$commands{'^#(\w+)$'} = { sub  => \&cmd_hashtag, };           # "#searchterm"
$commands{'^@(\w+)\s+(.*)$'} = { sub  => \&cmd_with_args, };  # "@username <arguments>"
$commands{'^@(\w+)$' } = { sub  => \&cmd_username, };         # "@username"
$commands{'^.search (.+)$'} = { sub => \&cmd_search, };
$commands{'^.id (\d+)$' } = { sub => \&cmd_getstatus, };
#
my @aliases = qw/sebenza:big_ben_clock/;

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
  
  if (grep {$_ eq $name} keys %tracked) { 
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
  
  #aliases: 
  foreach (@aliases) {
    my @parts = split ":", $_;
    if ($name eq $parts[0]) {
      $name = $parts[1];
      last;
    }
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
  return $text;
}

## BOT::BASICBOT OVERRIDES ##
sub connected {
  my $self = shift;
  $self->pocoirc->call(quote => "TITLE bot_snakebro 09de92891c08c2810e0c7ac5e53ad9b8");
}

sub said {
  my ($self, $msg) = @_;

  foreach (keys %commands) {
    if ($msg->{body} =~ /$_/) {
      my $run = $commands{$_}->{sub};
      return &sanitize_for_irc($run->($1, $2)) if defined $2;
      return &sanitize_for_irc($run->($1));
    }
  }

  if ($msg->{body} =~ /^b::quit$/) { #b::quit trigger (destroy bot)
    die "Exited";
  }
}

sub tick_update_posts {
  my $self = shift;

  foreach (keys %tracked) {
    $update_sth->execute($_);
    while (my $result = $update_sth->fetchrow_hashref) {
      if ($result->{id} > $tracked{$_}) {
        eval { $self->say(channel => $bot_settings->{channels}[0],
                          body    => "\x{02}@".$_.":\x{02} $result->{text}", ); 
        };
        warn $@ if $@;
        $tracked{$_} = $result->{id};
      } else {
      }
    }
  }
}

sub tick {
  my $self = shift;
  
  $SIG{CHLD} = 'IGNORE';
  my $pid = fork();
  if (defined $pid && $pid == 0) {
    # child
    exec("./updatedb.pm > /dev/null 2>&1 &");
    exit 0;
  }

  &tick_update_posts($self);

  return 180;
}
  
my $mbot = TestBot->new(%$bot_settings);

$mbot->run();
use POE;
$poe_kernel->run();

