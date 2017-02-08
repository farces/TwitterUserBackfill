#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use 5.010;
use YAML::XS qw/LoadFile/;
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

my $startup = 1; # this gets reset after first tick_update_posts is run
                 # so that no posts pulled from the startup updatedb
                 # are posted

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
my ($settings) = YAML::XS::LoadFile($twitter_cfg_file);
my $bot_settings = YAML::XS::LoadFile($bot_cfg_file);

#database
my $dbh = DBI->connect("dbi:SQLite:dbname=twitter.db","","");
my $default_sth = $dbh->prepare("SELECT text FROM tweets WHERE user=? ORDER BY ID DESC LIMIT 1");
my $random_sth = $dbh->prepare("SELECT text FROM tweets WHERE user=? ORDER BY RANDOM() LIMIT 1;");
my $insert_sth = $dbh->prepare("INSERT INTO tweets (id, user, text) VALUES (?,?,?)");

print "Loading twitter OAuth\n";

use Net::Twitter::Lite::WithAPIv1_1;
my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
  traits              => [qw/OAuth API::REST API::Search RetryOnError/],
  user_agent_args     => { timeout => 8, }, #required for cases where twitter holds a connection open
  consumer_key         => $settings->{consumer_key},
  consumer_secret      => $settings->{consumer_secret},
  access_token         => $settings->{access_token},
  access_token_secret  => $settings->{access_token_secret},
  ssl                  => 1,
);

#display user profile details
my $user_details = $nt->update_profile();
print "Logged in as: $user_details->{name} ($user_details->{screen_name})\n";
#

#this now loads tracked users from twitter's following users list
print "Loading followed users...\n";
my ($friends_list, %tracked);
eval {
  $friends_list = $nt->friends_list();
};
print $@ if $@;

#for each tracked user, find the latest id in the database for them
foreach (@{$friends_list->{users}}) {
  #$tracked{lc $_->{screen_name}} = &latest_from_db(lc $_->{screen_name});
  $tracked{lc $_->{screen_name}} = { latest => -1, new => 1, };
}
print "Following: ".join(",", keys %tracked)."\n";
#

my $latest_id = 0;
my $init_statuses = $nt->home_timeline({ exclude_replies => 1, });
for my $status (@$init_statuses) {
  $latest_id = $status->{id} if $status->{id} gt $latest_id;
}
print "Latest timeline ID: $latest_id\n";

#fork child to handle commands
my $pid = fork();
my (%commands, %aliases, @commands_list);
if (defined $pid && $pid == 0) {
  #this block contains child set-up, including all command-related code and variables
  #to ensure the parent doesn't hold on to any unnecessary data and prevent multiple
  #initialization of net::twitter::lite
  print "Starting command handler\n";
  print "Loading commands\n";
  $commands{'^.help\s*(.*)$'} = { handler => \&cmd_help, };
  $commands{'^#(\w+)$'} = { handler => \&cmd_hashtag, };           # #<hashtag>
  $commands{'^@(\w+)\s+(.*)$'} = { handler  => \&cmd_with_args, };  # @<username> <arguments>
  $commands{'^@(\w+)$' } = { handler => \&cmd_username, };         # @<username>
  $commands{'^\.search (.+)$'} = { handler => \&cmd_search,
    friendly => ".search",
    help => ".search <terms> - Search for <terms> in public timelines" };      # .search <terms>
  $commands{'^\.id (\d+)$' } = { handler => \&cmd_getstatus,
    friendly => ".id",
    help => ".id <id> - Display tweet with id <id>" };     # .id <id_number>
  $commands{'^\.trends\s*(.*)$' } = { handler => \&cmd_gettrends,
    friendly => ".trends",
    help => ".trends [woeid] - Display trends for region [woeid], default US" };# .trends <WOEID>
  $commands{'^\.follow (.+)$' } = { handler => \&cmd_addwatch,
    friendly => ".follow",
    help => ".follow <username> - Follow <username>, <username> should not include leading @" }; # .addwatch <username>
  $commands{'^\.unfollow (.+)$' } = { handler => \&cmd_delwatch,
    friendly => ".unfollow",
    help => ".unfollow <username> - Unfollow <username>, <username> should not include leading @" }; # .delwatch <username>
  $commands{'^\.update$' } = { handler => \&cmd_update,
    friendly => ".update",
    help => ".update - Refresh list of followed users" };        # .update
  $commands{'^\.quit$' } = {
    handler => sub { return &gen_response({ action => "EXIT" }, "SYS"); },
    };  # .quit
  $commands{'^\.list$' } = { handler => \&cmd_listwatch,
    friendly => ".list",
    help => ".list - List currently followed users" };          # .list
  $commands{'^https:\/\/twitter.com\/\w+\/status\/(\d+)$' } = { handler => \&cmd_getstatus,
    friendly => "Full https://twitter.com/user/status/123456 URL - show tweet", };
  foreach (keys %commands) {
    push @commands_list, $commands{$_}->{friendly} if defined $commands{$_}->{friendly};
  }

  %aliases = ("sebenza" => "big_ben_clock",);

  #start command handler
  &chandler;
  print "Chandler exited\n";
  exit 0;
}

#parent only from now on
close $PARENT;
undef %aliases; undef %commands;

use Encode qw/encode decode/;
use HTML::Entities qw/decode_entities/;
use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::IRC::Util qw/prefix_nick/;

my $c = AnyEvent->condvar;
my $con = new AnyEvent::IRC::Client;

print "Performing background backfill.\n";
&backfill;

#commands
sub cmd_addwatch {
  my $name = shift;
  say "Adding watched user: $name";
  if (!defined $tracked{$name}) {
    my @response;
    #$tracked{$name} = &latest_from_db($name); #child has a separate copy of tracked
    $tracked{$name} = { latest => -1, new => 1, };
    $nt->create_friend({ screen_name => $name, });
    push @response, &gen_response({ action => "SET_FOLLOWING", following => \%tracked, }, "SYS");
    push @response, &gen_response("$name added.");
    return @response;
  }
    return &gen_response("$name already tracked.");
}

sub cmd_delwatch {
  my $name = shift;
  say "Removing watched user: $name";
  if (!defined $tracked{$name}) {
    return &gen_response("Not currently following $name");
  }

  delete $tracked{$name};
  $nt->unfollow({ screen_name => $name, });
  my @response;
  push @response, &gen_response({ action => "SET_FOLLOWING", following => \%tracked, }, "SYS");
  push @response, &gen_response("$name removed.");
  return @response;
}

sub cmd_listwatch {
  say "Listing followed users.";
  return &gen_response("Currently following: ".join(", ", keys %tracked));
}

sub cmd_update {
  my $friends_list;
  eval {
    $friends_list = $nt->friends_list();
  };
  print $@ if $@;

  #for each tracked user, find the latest id in the database for them
  foreach (@{$friends_list->{users}}) {
    $tracked{lc $_->{screen_name}} = { latest => -1, new => 1, };
  }
  return &gen_response({ action => "SET_FOLLOWING", following => \%tracked, }, "SYS");
}

sub cmd_help {
  my $which = shift;
  return &gen_response(join(", ", @commands_list)) unless $which;

  $which =~ s/^\.//; # strip leading . if provided.
  foreach (%commands) {
    next unless defined $commands{$_}->{friendly};
    if ($commands{$_}->{friendly} eq ".".$which) {
      return &gen_response($commands{$_}->{help});
      last;
    }
  }

}

sub cmd_username {
  my $name = shift;
  say "Searching: @".$name;
  #if username is one that is listed in the config, pull an entry from the db
  if (grep {$_ eq $name} keys %tracked) {
    my $result = $dbh->selectrow_hashref($random_sth,undef,lc $name);
    return &gen_response($result->{text}) if defined $result;
  } else {
    my $result = &search_username($name);
    return &gen_response($result) if defined $result;
  }
  return;
}

sub cmd_with_args {
  my ($name, $args) = @_;
  if (grep {$_ eq $name} keys %tracked) {
    if ($args eq "latest") {
      my $result = $dbh->selectrow_hashref($default_sth,undef, lc $name);
      return &gen_response($result->{text});
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
  return &gen_response($result) if defined $result;
}

sub cmd_gettrends {
  my $woeid = shift;
  $woeid = "23424977" if not $woeid;
  say "Getting trends for WOEID: $woeid";
  my $trends = eval { $nt->trends($woeid); };
  warn "cmd_gettrends() error: $@" if $@;
  return unless defined $trends;
  my @names;
  for (@{@{$trends}[0]->{trends}}) {
    push @names, $_->{name};
  }
  return &gen_response("\x{02}Trending:\x{02} ".join( ', ', @names )) if scalar(@names);
}

sub cmd_search {
  my $query = shift;
  say "Searching: $query";
  my $result = &search_generic($query);
  return &gen_response($result) if defined $result;
}

sub cmd_getstatus {
  my $id = shift;
  say "Getting status: $id";
  my $result = &get_status($id);
  return &gen_response($result) if defined $result;
}
#

#unfortunately get_status, search_username and search_generic have to be separate
#as they all access different API portions (show_status, user_timeline and search
#respectively)
#these should return nothing if no result was found
sub get_status {
  my $id = shift;
  my $status = eval { $nt->show_status({ id => $id, tweet_mode => 'extended', }); };
  #throws an error if no status is retrieved
  #warn "get_status() error: $@" if $@;
  return unless defined $status;
  return "\x{02}@".$status->{user}->{screen_name}.":\x{02} ".($status->{full_text} || $status->{text});
}

sub search_username {
  my $name = shift;
  if ($aliases{$name}) {
    $name = $aliases{$name};
  }

  my $statuses = eval { $nt->user_timeline({ id => "$name", count => 1, tweet_mode => 'extended', }); };
  warn "search_username(); error: $@" if $@;
  return if $@;
  return @$statuses[0]->{full_text} ? @$statuses[0]->{full_text} : @$statuses[0]->{text} if @$statuses;
}

sub search_generic {
  my $name = shift;
  my $statuses = eval { $nt->search({q => $name, lang => "en", count => 1, tweet_mode => 'extended', }); };
  warn "get_tweets(); error: $@" if $@;
  return unless defined @{$statuses->{statuses}}[0];
  my $r = &find_original(@{$statuses->{statuses}}[0]);
  return "\x{02}@".$r->{user}->{screen_name}."\x{02}: ".($r->{full_text}||$r->{text})." - http://twitter.com/$r->{user}->{screen_name}/status/$r->{id}";
}

# chooses retweet text if it exists
sub find_original {
  my $status = shift;
  return $status->{retweeted_status} ? $status->{retweeted_status} : $status;
}

sub gen_response {
  my $args = shift;
  my $opcode = shift;
  $opcode = "REP" if !defined $opcode;
  my $result = { op => $opcode, payload => { msg => $args, }, };
  return $result;
}

#saves the $settings hash to file, since updatedb.pm loads it externally.
#$settings be live-updated to add/remove tracked users
sub save_settings {
  open CONFIG, ">", $twitter_cfg_file or die $!;
  print CONFIG YAML::XS::Dump($settings);
  close CONFIG;
  say "Settings saved.";
}

sub sanitize_for_irc {
  my $text = shift;
  return unless defined $text;
  $text =~ s/\n/ /g;
  $text = HTML::Entities::decode($text);
  return $text
}

sub get_timeline_new {
  my $tmp_latest = $latest_id;

  my $result;
  eval {
    $result = $nt->home_timeline({ exclude_replies => 1, tweet_mode => "extended" });
  };

  for my $status (@$result) {
    if ($status->{id} gt $latest_id) {
      $tmp_latest = $status->{id} if $status->{id} gt $tmp_latest;
      my $message = $status->{full_text} ? $status->{full_text} : $status->{text};
      &send_message($bot_settings->{channels}[0], "\x{02}@".$status->{user}->{screen_name}.":\x{02} $message");
      $insert_sth->execute($status->{id},lc $status->{user}->{screen_name}, $status->{full_text}||$status->{text});
    }
  }
  $latest_id = $tmp_latest;
}

sub send_message {
  my $target = shift;
  my $message = shift;
  # WHAT ON EARTH
  utf8::encode($message) if utf8::is_utf8($message);
  $con->send_srv(PRIVMSG => $target, &sanitize_for_irc($message));
}


sub tick {
  # reconnect if the connection is down
  if (not $con->heap->{is_connected}) {
    &connect;
  }
  # don't get any new timeline stuff if we're acting dumb (just responding to commands)
  &get_timeline_new unless $opt_d;

  return;
}

sub backfill {
  my $pid = fork();
  if (defined $pid && $pid == 0) {
    exec("./updatedb.pm -s $twitter_cfg_file > /dev/null 2>&1 &");
    exit 0;
  }
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

    if ($work->{msg} eq "UPDATE") {
      %tracked = %{$work->{data}};
      next;
    }
    foreach (keys %commands) {
      if ($work->{msg} =~ /$_/) {
        my $run = $commands{$_}->{handler};
        #run command, with regexp matches $1 and $2 if defined (allows bare .command handling).
        my @result = $run->(defined $1 ? lc $1 : undef , defined $2 ? lc $2 : undef);

        my @final;
        foreach (@result) {
          #if item is not a ref, we've gotten an empty response from $run
          if (ref($_)) {
            $_->{payload}->{target} = $work->{target} if !defined $_->{payload}->{target};
            push @final, $_;
          }
        }
        print $PARENT encode_json(\@result)."\n" if @final;
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
    $msg->{params}[1] = decode('utf8',$msg->{params}[1]);
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

  foreach (@$data) {
    my $op = $_->{op};
    if ($op eq "REP") {
      #REPLY action, payload => msg, target
      &send_message($_->{payload}->{target}, $_->{payload}->{msg});
      #$con->send_srv(PRIVMSG => $_->{payload}->{target}, &sanitize_for_irc($_->{payload}->{msg}));
    } elsif ($op eq "SYS") {
      #SYSTEM action, payload => msg => action, [optional]
      my $message = $_->{payload}->{msg};
      if ($message->{action} eq "EXIT") {
        #SYS:EXIT msg => name
        undef $w;
        $c->broadcast;
      } elsif ($message->{action} eq "SET_FOLLOWING") {
        %tracked = %{$message->{following}};
        &backfill;
        #&tick_update_posts;
      }
    }
  }
});

&connect;
$c->wait;
