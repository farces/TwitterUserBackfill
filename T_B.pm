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
use List::Util qw/min/;
use Scalar::Util qw/blessed/;

sub process {
    #&process($statuses_from_user_timeline,\&post_process_func);
    #Subroutine for storing statuses to whichever data store required.
    #Returns: lowest inserted ID, or an empty array if none. Lowest ID
    #required for next user_timeline request.
    my ($self,$statuses,$func) = @_;
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
    say "Get $name" if $self->{debug};
    
    $statuses = $self->twitter_timeline({id => "$name", count => $self->{posts_per_request}, });

    my $min = $self->process($statuses,$func);
    if (not defined $min) {
        say "Error retrieving first batch for $name. Skipping." if $self->{debug};
        return;
    }

    return 0 if (scalar(@$statuses) < ($self->{posts_per_request}-25));

    my $new_min;
    while(1) {
        $statuses = $self->twitter_timeline({id => "$name", 
                                 count => $self->{posts_per_request}, 
                                 max_id => $min,});
        last unless $statuses;

        $new_min = $self->process($statuses,$func);
        last unless ($new_min < $min);
        
        last if (scalar(@$statuses) < ($self->{posts_per_request}-25));
        $min = $new_min;
        sleep($self->{request_rate});
    }
}

sub default_action {
    #dummy function that just prints the 'text' field of each status
    #it is passed. Place any of your data storage actions here (one call
    #per status)
    my ($self,$status) = @_;
    say $status->{text};
}

sub new {
    my ($class, %args) = @_;
    my $new = bless {
        posts_per_request   => 125,
        request_rate        => 2,
        count               => 0,
        debug               => 0,
        twitter_i           => undef,
        %args
    }, $class;
    return $new;
}

sub connect {
    my $self = shift;
    $self->{twitter_i} = Net::Twitter::Lite->new(
        consumer_key => $self->{consumer_key},
        consumer_secret => $self->{consumer_secret},
        access_token    => $self->{access_token},
        access_token_secret => $self->{access_token_secret}
    );
}


#my %test = ('users' => {
#		'snakebro' => 1, 
#		'jerkcity' => 0,
#        'sdkjghsdkghsdglsdk' => 0,});

#foreach (keys %{$test{'users'}}) {
#    &backfill($_);
#}
1;
