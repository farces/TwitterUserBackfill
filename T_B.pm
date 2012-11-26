#A semi-optimal script for retrieving a given users entire user_timeline.

#Algorithim requests:
# [total_post_count/$posts_per_request] + 1 + {response_502_retries}
#Adjust $posts_per_request lower if your average user has less posts
#than $posts_per_request, higher if they have more, with a ceiling of 
#~125 before Twitter starts returning additional 502 responses. 
#Default: 125.

package T_B;

use strict;
use warnings;
use 5.010;
use Net::Twitter::Lite qw/new user_timeline/;
use List::Util qw/min max/;
use Scalar::Util qw/blessed/;

sub _process {
    my ($self,$statuses,$func) = @_;
    my @ids;
    for my $status (@$statuses) {
        $func->($status); #perform post-process action on $status
        push @ids, int($status->{id});
    }
    my $low = min @ids;
    my $high = max @ids;
    return $low, $high;
}

sub _twitter_timeline {
    my ($self,$args) = @_;
    my $statuses;

    for (my $wait=2;$wait<=128;$wait*=2) {
        $self->{count}++;
        say "Request $self->{count}." if $self->{debug};
        $statuses = eval {
            $self->{twitter_i}->user_timeline($args);
        };
        if (my $error = $@) {
            if (blessed $error && $error->isa("Net::Twitter::Lite::Error")
                 && $error->code() == 502) {
                say "502 error, retrying in $wait seconds." if $self->{debug};
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
    my ($self, $name, $func) = @_;
    my $statuses;
    $self->{count}=0;

    if (not defined $name) { die "ERROR: username must be provided."; }
    if (not defined $func) { die "ERROR: You must pass a callback sub to backfill()."; }
    
    say "Get $name" if $self->{debug};
    
    $statuses = $self->_twitter_timeline({id => "$name", count => $self->{posts_per_request}, });
    my ($min,$max) = $self->_process($statuses,$func);

    if (not defined $min) {
        say "Error retrieving first batch for $name. Skipping." if $self->{debug};
        return;
    }

    #if statuses returned are < the criteria for determining if all posts
    #were returned in a single request, return
    return 0 if (scalar(@$statuses) < ($self->{posts_per_request}-120));
    
    my $new_min;
    while(1) {
        $statuses = $self->_twitter_timeline({
            id => "$name", 
            count => $self->{posts_per_request}, 
            max_id => $min,
        });
        last unless $statuses;

        ($new_min,$max) = $self->_process($statuses,$func);
        last if not defined $new_min;
        last unless ($new_min < $min);
        
        last if (scalar(@$statuses) < ($self->{posts_per_request}-120));
        $min = $new_min-1;
        sleep($self->{request_rate});
    }
}

sub recent {
    #returns recent tweets for a user. apparently requests using since_id can still return old
    #results :downs:
    my ($self, $name, $func, $max) = @_;
    my $statuses;
    if (not defined $name) { die "ERROR: username must be provided."; }
    if (not defined $func) { die "ERROR: You must pass a callback sub to recent()."; }
    if (not defined $max) { die "ERROR: latest existing ID must be provided."; }
    
    while (1) {
        $statuses = $self->_twitter_timeline({
                id => "$name", 
                since_id => $max, 
            });
        last unless $statuses;
        my ($min,$new_max) = $self->_process($statuses, $func);
        last if not defined $new_max;
        last unless ($new_max > $max);
        last if scalar(@$statuses) < 10;
        $max = $new_max;
        sleep($self->{request_rate})
    }
}

sub new {
    my ($class, %args) = @_;
    my $new = bless {
        posts_per_request   => 125,
        request_rate        => 2,
        count               => 0,
        debug               => 0,
        twitter_i           => undef,
        net_twitter_args    => \%args
    }, $class;
    return $new;
}

sub connect {
    my $self = shift;
    $self->{twitter_i} = Net::Twitter::Lite->new(%{$self->{net_twitter_args}});
    return $self;
}

1;
