#!/usr/bin/env perl
# NexusGGR / FiversCan API — Perl 5 integration sample (core modules only)
# =========================================================================
# Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
# Auth      : every request body carries agent_code + agent_token
# Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
#             {"status": 0, "msg": "<ERROR>"}        on failure
# Methods   : provider_list, game_list, user_create, user_deposit,
#             game_launch, money_info, user_withdraw
# API access: https://t.me/casino_api777  ·  https://nexusggr.games
#
# Run (HTTPS needs IO::Socket::SSL, usually already installed):
#   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... perl index.pl

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use Time::HiRes qw(time);

my $API_URL     = $ENV{FVS_API_URL}     // 'https://api.example.com';   # API server you received from NexusGGR
my $AGENT_CODE  = $ENV{FVS_AGENT_CODE}  // 'your_agent_code';
my $AGENT_TOKEN = $ENV{FVS_AGENT_TOKEN} // 'your_agent_token';

package FiversCanClient {
    sub new {
        my ($class, %args) = @_;
        return bless {
            api_url     => $args{api_url},
            agent_code  => $args{agent_code},
            agent_token => $args{agent_token},
            http        => HTTP::Tiny->new(timeout => 15),
            json        => JSON::PP->new->utf8->canonical,
        }, $class;
    }

    # Low-level call: POST {method, agent_code, agent_token, %params} and unwrap status.
    # On an API error dies with a hashref { method, msg, detail } so callers can inspect msg.
    sub call {
        my ($self, $method, %params) = @_;
        my $body = $self->{json}->encode({
            method      => $method,
            agent_code  => $self->{agent_code},
            agent_token => $self->{agent_token},
            %params,
        });

        my $res = $self->{http}->post($self->{api_url}, {
            headers => { 'Content-Type' => 'application/json' },
            content => $body,
        });
        die "$method: HTTP $res->{status} $res->{reason}\n" unless $res->{success};

        my $data = $self->{json}->decode($res->{content});
        if (($data->{status} // 0) != 1) {
            die { method => $method, msg => $data->{msg} // 'unknown', detail => $data->{detail} };
        }
        return $data;
    }

    sub provider_list { $_[0]->call('provider_list') }

    sub game_list { my ($self, $provider_code) = @_; $self->call('game_list', provider_code => $provider_code) }

    sub user_create { my ($self, $user_code) = @_; $self->call('user_create', user_code => $user_code) }

    # amount must be a JSON number: add 0 so JSON::PP encodes it as a number, not a string.
    # agent_sign is an optional unique id ([A-Za-z0-9_]) that prevents double-charging on retries.
    sub user_deposit {
        my ($self, $user_code, $amount, $agent_sign) = @_;
        $self->call('user_deposit', user_code => $user_code, amount => $amount + 0, ($agent_sign ? (agent_sign => $agent_sign) : ()));
    }

    sub user_withdraw {
        my ($self, $user_code, $amount, $agent_sign) = @_;
        $self->call('user_withdraw', user_code => $user_code, amount => $amount + 0, ($agent_sign ? (agent_sign => $agent_sign) : ()));
    }

    # Without user_code returns the agent balance only; with all_users => JSON::PP::true returns every user
    sub money_info { my ($self, $user_code) = @_; $self->call('money_info', ($user_code ? (user_code => $user_code) : ())) }

    # game_code may be empty for live-casino providers to open the lobby; rtp is optional
    sub game_launch {
        my ($self, %a) = @_;
        $self->call('game_launch',
            user_code     => $a{user_code},
            provider_code => $a{provider_code},
            game_code     => $a{game_code} // '',
            lang          => $a{lang} // 'en',
            lobby_url     => $a{lobby_url} // '',
            (defined $a{rtp} ? (rtp => $a{rtp} + 0) : ()),
        );
    }
}

sub main {
    my $fvs = FiversCanClient->new(api_url => $API_URL, agent_code => $AGENT_CODE, agent_token => $AGENT_TOKEN);
    my $user_code = 'demo_user';

    # 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    my $providers = $fvs->provider_list->{providers};
    my ($provider) = grep { $_->{status} == 1 } @$providers;
    $provider //= $providers->[0];
    printf "providers: %d, using %s\n", scalar @$providers, $provider->{code};

    # 2. Games of that provider
    my $games = $fvs->game_list($provider->{code})->{games};
    my $game = $games->[0];
    printf "games: %d, first: %s (%s)\n", scalar @$games, $game->{game_code}, $game->{game_name};

    # 3. Create the player (idempotent: an existing user is fine)
    my $created = eval { $fvs->user_create($user_code) };
    if ($created) {
        printf "user created: %s (%s)\n", $created->{user_code}, $created->{fc_code};
    } elsif (ref $@ eq 'HASH' && $@->{msg} =~ /duplicated/i) {
        printf "user exists: %s\n", $user_code;
    } else {
        die $@;
    }

    # 4. Move funds agent -> player
    my $dep = $fvs->user_deposit($user_code, 100, 'dep_' . int(time() * 1000));
    printf "deposit ok: agent=%s user=%s\n", $dep->{agent_balance}, $dep->{user_balance};

    # 5. Get the game URL to open in the player's browser / iframe
    my $launch = $fvs->game_launch(user_code => $user_code, provider_code => $provider->{code}, game_code => $game->{game_code}, lang => 'en', lobby_url => 'https://your-site.com/lobby');
    printf "launch_url: %s\n", $launch->{launch_url};

    # 6. Balances
    my $info = $fvs->money_info($user_code);
    printf "balance: agent=%s user=%s\n", $info->{agent}{balance}, $info->{user}{balance};

    # 7. Move funds player -> agent
    my $wd = $fvs->user_withdraw($user_code, 50, 'wd_' . int(time() * 1000));
    printf "withdraw ok: agent=%s user=%s\n", $wd->{agent_balance}, $wd->{user_balance};
}

eval { main(); 1 } or do {
    my $err = $@;
    print STDERR (ref $err eq 'HASH' ? "$err->{method} failed: $err->{msg}" . ($err->{detail} ? " ($err->{detail})" : '') : $err), "\n";
    exit 1;
};
