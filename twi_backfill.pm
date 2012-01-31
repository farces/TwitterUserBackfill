#!/usr/bin/perl
#A semi-optimal script for retrieving a given users entire user_timeline.

#Algorithim requests:
# [total_post_count/$posts_per_request] + 1 + {response_502_retries}
#Adjust $posts_per_request lower if your average user has less posts
#than $posts_per_request, higher if they have more, with a ceiling of 
#~125 before Twitter starts returning additional 502 responses. 
#Default: 125.

use strict;
use warnings;
use 5.010;
use Net::Twitter::Lite;
use List::Util qw/min/;
use Scalar::Util qw/blessed/;

binmode STDOUT, ":utf8";

my $nt = Net::Twitter::Lite->new(
    consumer_key    => "your_consumer_key",
    consumer_secret => "your_consumer_secret",
    access_token    => "your_access_token",
    access_token_secret => "your_access_token_secret"
);

my $no_debug = 1;
my $count;
my $posts_per_request = 125;
my $request_rate = 2; #seconds between requests

sub process {
    #&process($statuses_from_user_timeline,\&post_process_func);
    #Subroutine for storing statuses to whichever data store required.
    #Returns: lowest inserted ID, or an empty array if none. Lowest ID
    my ($statuses,$func) = @_;
    my @ids;
    for my $status (@$statuses) {
        $func->($status); #perform post-process action on $status
        push @ids, int($status->{id});
    }
    my $low = min @ids;
    return $low;
}

sub twitter_timeline {
    #$statuses = &twitter_timeline({user_timeline arguments});
    #Calls user_timeline, handling any returned errors and retrying if required.
    #Return: the result of user_timeline() unmodified.
    my $args = shift;
    my $statuses;

    for (my $wait=2;$wait<=128;$wait*=2) {
        $count++;
        say "Request $count." unless $no_debug;
        $statuses = eval {
            $nt->user_timeline($args);
        };
        if (my $error = $@) {
            if (blessed $error && $error->isa("Net::Twitter::Lite::Error")
                 && $error->code() == 502) {
                say "502 error, retrying in $wait seconds." unless $no_debug;
                sleep($wait);
                next;
            }
            warn $@; #handle non-502 errors e.g. rate limit, unknown user.
            last;    #by dropping out of the loop, as it is unrecoverable.
        }
        last;
    }
    return $statuses;
}

sub backfill {
    #&backfill('id',\&post_process_func);
    #Gets all historical tweets for user.
	my ($name, $func) = @_;
    my $statuses;
    $count=0;
    say "Get $name" unless $no_debug;
    
    $statuses = &twitter_timeline({id => "$name", count => $posts_per_request, });

    my $min = &process($statuses,$func);
    if (not defined $min) {
        say "Error retrieving first batch for $name. Skipping." unless $no_debug;
        return;
    }

    return 0 if (scalar(@$statuses) < ($posts_per_request-25));

    my $new_min;
    while(1) {
        $statuses = &twitter_timeline({id => "$name", 
                                 count => $posts_per_request, 
                                 max_id => $min,});
        last unless $statuses;

        $new_min = &process($statuses,$func);
        last unless ($new_min < $min);
        
        last if (scalar(@$statuses) < ($posts_per_request-25));
        $min = $new_min;
        sleep($request_rate);
    }
}

sub custom_action {
    #dummy function that just prints the 'text' field of each status
    #it is passed. Place any of your data storage actions here (one call
    #per status)
    my $status = shift;
    say $status->{text};
}

&backfill('hambargler',\&custom_action);
