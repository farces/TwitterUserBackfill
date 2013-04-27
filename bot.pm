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
my $update_sth = $dbh->prepare("SELECT id, text FROM tweets WHERE user=? ORDER BY ID DESC LIMIT 5");

print "Loading twitter OAuth\n";

use Net::Twitter::Lite::WithAPIv1_1;
my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
  traits              => [qw/OAuth API::REST API::Search RetryOnError/],
  user_agent_args     => { timeout => 8 }, #required for cases where twitter holds a connection open
  consumer_key         => $settings->{consumer_key},
  consumer_secret      => $settings->{consumer_secret},
  access_token         => $settings->{access_token},
  access_token_secret  => $settings->{access_token_secret},
);

#this now loads tracked users from twitter's following users list
print "Loading tracked users... ";
my ($friends_list, %tracked);
eval {
  $friends_list = $nt->friends_list();
};
print $@ if $@;

#for each tracked user, find the latest id in the database for them
foreach (@{$friends_list->{users}}) {
  $tracked{lc $_->{screen_name}} = &latest_from_db(lc $_->{screen_name});
}
#

#fork child to handle commands
my $pid = fork();
my (%commands, %aliases);
if (defined $pid && $pid == 0) {
  #this block contains child set-up, including all command-related code and variables
  #to ensure the parent doesn't hold on to any unnecessary data and prevent multiple
  #initialization of net::twitter::lite
  print "Starting command handler\n";
  print "Loading commands\n";

  $commands{'^#(\w+)$'} = { handler => \&cmd_hashtag, };           # #<hashtag>
  $commands{'^@(\w+)\s+(.*)$'} = { handler  => \&cmd_with_args, };  # @<username> <arguments>
  $commands{'^@(\w+)$' } = { handler => \&cmd_username, };         # @<username>
  $commands{'^\.search (.+)$'} = { handler => \&cmd_search, };      # .search <terms>
  $commands{'^\.id (\d+)$' } = { handler => \&cmd_getstatus, };     # .id <id_number>
  $commands{'^\.trends\s*(.*)$' } = { handler => \&cmd_gettrends, };# .trends <WOEID>
  $commands{'^\.follow (.+)$' } = { handler => \&cmd_addwatch, }; # .addwatch <username>
  $commands{'^\.unfollow (.+)$' } = { handler => \&cmd_delwatch, }; # .delwatch <username>
  $commands{'^\.quit$' } = { 
    handler => sub { return &gen_response({ action => "EXIT" }, "SYS"); }, 
    };  # .quit
  $commands{'^\.list$' } = { handler => \&cmd_listwatch, };          # .list
  
  %aliases = ("sebenza" => "big_ben_clock",);
  
  #start command handler
  &chandler;
  print "Chandler exited\n";
  exit 0;
}

#parent only from now on
close $PARENT;
undef %aliases; undef %commands;

use Encode qw/encode/;
use HTML::Entities qw/decode_entities/;
use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::IRC::Util qw/prefix_nick/;

my $c = AnyEvent->condvar;
my $con = new AnyEvent::IRC::Client;

print "Following: ".join(",", keys %tracked)."\n";

#commands
sub cmd_addwatch {
  my $name = shift;
  say "Adding watched user: $name";
  if (!defined $tracked{$name}) {
    my @response; 
    $tracked{$name} = &latest_from_db($name); #child has a separate copy of tracked
    $nt->create_friend({ screen_name => $name, });
    push @response, &gen_response({ action => "ADD_WATCH", name => $name, }, "SYS");
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
  push @response, &gen_response({ action => "DEL_WATCH", name => $name, }, "SYS");
  push @response, &gen_response("$name removed.");
  return @response;
}

sub cmd_listwatch {
  say "Listing followed users.";
  return &gen_response("Currently following: ".join(", ", keys %tracked));
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
  my $trends = eval { $nt->trends_location($woeid); };
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
  return unless defined @{$statuses->{statuses}}[0];
  my $r = @{$statuses->{statuses}}[0];
  return "\x{02}@".$r->{user}->{screen_name}."\x{02}: $r->{text} - http://twitter.com/$r->{user}->{screen_name}/status/$r->{id}";
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

sub latest_from_db {
  my $name = shift;
  my $result = $dbh->selectrow_hashref($update_sth,undef,lc $name);
  if (defined $result) {
    return $result->{id};
  } else {
    return 0;
  }
}

sub sanitize_for_irc {
  my $text = shift;
  return unless defined $text;
  $text =~ s/\n/ /g;
  $text = HTML::Entities::decode($text);
  return encode('utf8', $text);
}

sub tick_update_posts {
  foreach (keys %tracked) {
    $update_sth->execute(lc $_);
    while (my $result = $update_sth->fetchrow_hashref) {
      if ($result->{id} > $tracked{$_}) {
        if (!defined $opt_d) {
          eval {
            #TODO: move this dumb shit into some helper function that automatically sanitizes
            #the message and just call that.
            my $tweet = &sanitize_for_irc($result->{text});
            $con->send_srv(PRIVMSG => $bot_settings->{channels}[0], "\x{02}@".$_.":\x{02} $tweet");
          };
        }
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
  &tick_update_posts;
  
  return if defined $opt_d; #finish up if we're dumb

  my $pid = fork();
  if (defined $pid && $pid == 0) {
    # child
    #exec("./updatedb.pm > /dev/null 2>&1 &");
    exec("./get_new.pm -s $twitter_cfg_file > /dev/null 2>&1 &");
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
      $con->send_srv(PRIVMSG => $_->{payload}->{target}, &sanitize_for_irc($_->{payload}->{msg}));
    } elsif ($op eq "SYS") {
      #SYSTEM action, payload => msg => action, [optional]
      my $message = $_->{payload}->{msg};
      if ($message->{action} eq "EXIT") {
        #SYS:EXIT msg => name
        undef $w;
        $c->broadcast;
      } elsif ($message->{action} eq "ADD_WATCH") {
        #SYS:Add new watched user: msg => name
        push @{$settings->{users}}, $message->{name};
        $tracked{$message->{name}} = &latest_from_db($message->{name});
        &save_settings;
        &tick_update_posts;
      } elsif ($message->{action} eq "DEL_WATCH") {
        #SYS:Remove watched user: msg => name
        delete $tracked{$message->{name}};
        my $index = 0;
        $index++ until $settings->{users}[$index] eq $message->{name};
        splice(@{$settings->{users}},$index,1);
        &save_settings;
      }
    }
  }
});

&connect;
$c->wait;
