package PAGI::Middleware::Routing::_Fallback;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Context;
use PAGI::Routing::Trace;
use PAGI::Utils ();

sub new {
    my ($class, @options) = @_;

    croak "$class options must be an even-length list" if @options % 2;
    my %config = @options;
    for my $key (keys %config) {
        croak "unknown $class option '$key'" unless $key eq 'handler';
    }
    croak "$class handler must be a code reference"
        if exists($config{handler}) && ref($config{handler}) ne 'CODE';

    return $class->SUPER::new(%config);
}

sub _init {
    my ($self, $config) = @_;
    $self->{handler} = $config->{handler};
    return;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;

        if (($scope->{type} // 'http') ne 'http') {
            my $returned = $app->($scope, $receive, $send);
            await Future->wrap($returned);
            return;
        }

        my ($boundary_scope, $trace)
            = PAGI::Routing::Trace->_ensure_http_scope($scope);
        my $response_started = 0;
        my $observing_send = sub {
            my ($event) = @_;
            $response_started = 1
                if ($event->{type} // '') eq 'http.response.start';
            return $send->($event);
        };

        my $checkpoint = $trace->checkpoint;
        my $error;
        my $completed = eval {
            my $returned = $app->(
                $boundary_scope,
                $receive,
                $observing_send,
            );
            await Future->wrap($returned);
            1;
        };
        $error = $@ unless $completed;
        die $error unless $completed;

        return if $response_started;

        my $snapshot = $trace->snapshot($checkpoint);
        return unless $self->_matches($snapshot);

        my $context = PAGI::Context->new($boundary_scope, $receive, $send);
        $self->_seed_context($context);

        my $returned = $self->{handler}
            ? $self->{handler}->($context, $snapshot)
            : $self->_default_response($context, $snapshot);
        my $response = await Future->wrap($returned);
        croak 'handler did not return a response'
            unless PAGI::Utils::is_response($response);

        my $emitted = $self->_prepare_response($response, $snapshot);
        await Future->wrap($context->respond($emitted));
        return;
    };
}

sub _prepare_response {
    my ($self, $response, $snapshot) = @_;
    return $response;
}

sub _safe_fact {
    my ($self, $value) = @_;
    return '(none)' unless defined $value;
    return '(unavailable)' if ref $value;

    my $text = "$value";
    $text = substr($text, 0, 512) . '...' if length($text) > 512;
    $text =~ s/\\/\\\\/g;
    $text =~ s/\r/\\r/g;
    $text =~ s/\n/\\n/g;
    $text =~ s/\t/\\t/g;
    $text =~ s/([\x00-\x08\x0b\x0c\x0e-\x1f\x7f])/
        sprintf('\\x{%02X}', ord($1))/gex;
    return $text;
}

sub _attempt_diagnostics {
    my ($self, $snapshot) = @_;
    return ('Routing attempts: unavailable')
        unless $snapshot->details_available;

    my $attempts = $snapshot->attempts;
    return ('Routing attempts: none') unless @$attempts;

    my @lines = ('Routing attempts:');
    my $number = 0;
    for my $attempt (@$attempts) {
        ++$number;
        my @facts;
        for my $key (qw(candidate_kind namespace pattern name desc)) {
            next unless exists $attempt->{$key};
            push @facts, "$key=" . $self->_safe_fact($attempt->{$key});
        }
        push @facts, 'path_matched=' . ($attempt->{path_matched} ? 'yes' : 'no');
        push @facts, 'method_matched=' . ($attempt->{method_matched} ? 'yes' : 'no');
        push @lines, "  $number. " . join('; ', @facts);
    }
    push @lines, '  (additional attempts omitted)' if $snapshot->truncated;
    return @lines;
}

sub _plain_text_response {
    my ($self, $context, $text) = @_;
    require Encode;
    my $bytes = Encode::encode(
        'UTF-8',
        $text,
        Encode::FB_DEFAULT() | Encode::LEAVE_SRC(),
    );
    return $context->response
        ->content_type('text/plain; charset=utf-8')
        ->header('Cache-Control' => 'no-store')
        ->send_raw($bytes);
}

sub _matches {
    die 'routing fallback subclass must implement _matches';
}

sub _seed_context {
    die 'routing fallback subclass must implement _seed_context';
}

sub _default_response {
    die 'routing fallback subclass must implement _default_response';
}

1;
