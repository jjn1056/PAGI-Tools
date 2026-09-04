package PAGI::Auth;

use strict;
use warnings;
use Carp qw(croak);
use Exporter qw(import);
use Scalar::Util qw(blessed);
use PAGI::Auth::Challenge ();

our @EXPORT = ();
our @EXPORT_OK = qw(challenge forbid basic bearer custom_challenge);
our %EXPORT_TAGS = (
    outcomes   => [qw(challenge forbid)],
    challenges => [qw(basic bearer custom_challenge)],
    all        => [@EXPORT_OK],
);

sub basic {
    my %opts = _options('Basic', [qw(realm charset)], @_);

    croak 'Basic realm is required' unless exists $opts{realm};
    _quoted_value('Basic realm', $opts{realm});

    my @params = ('realm=' . _quote($opts{realm}));
    if (exists $opts{charset}) {
        _quoted_value('Basic charset', $opts{charset});
        croak 'Basic charset must be UTF-8'
            unless lc($opts{charset}) eq 'utf-8';
        push @params, 'charset="UTF-8"';
    }

    return PAGI::Auth::Challenge->_new(
        scheme       => 'Basic',
        header_value => 'Basic ' . join(', ', @params),
        kind         => 'basic',
        error        => undef,
    );
}

sub bearer {
    my %opts = _options(
        'Bearer',
        [qw(realm scope error error_description error_uri params)],
        @_,
    );

    _quoted_value('Bearer realm', $opts{realm}) if exists $opts{realm};
    _scope('Bearer scope', $opts{scope}) if exists $opts{scope};

    my $error = exists($opts{error})
        ? _token('Bearer error', $opts{error}) : undef;

    croak 'Bearer error_description requires error'
        if exists($opts{error_description}) && !exists($opts{error});
    _bearer_printable('Bearer error_description', $opts{error_description})
        if exists $opts{error_description};

    croak 'Bearer error_uri requires error'
        if exists($opts{error_uri}) && !exists($opts{error});
    _absolute_bearer_uri('Bearer error_uri', $opts{error_uri})
        if exists $opts{error_uri};

    my @extensions;
    if (exists $opts{params}) {
        @extensions = _params('Bearer params', $opts{params});
        my %core = map { $_ => 1 } qw(
            realm scope error error_description error_uri
        );
        for my $name (keys %{ $opts{params} }) {
            croak "Bearer params must not contain core name '$name'"
                if $core{lc $name};
        }
    }

    croak 'Bearer requires at least one parameter'
        unless exists($opts{realm}) || exists($opts{scope})
            || exists($opts{error}) || @extensions;

    my @serialized;
    push @serialized, 'realm=' . _quote($opts{realm}) if exists $opts{realm};
    push @serialized, 'scope=' . _quote(join ' ', @{ $opts{scope} })
        if exists $opts{scope};
    push @serialized, 'error=' . _quote($error) if exists $opts{error};
    push @serialized, 'error_description=' . _quote($opts{error_description})
        if exists $opts{error_description};
    push @serialized, 'error_uri=' . _quote($opts{error_uri})
        if exists $opts{error_uri};
    push @serialized, @extensions;

    return PAGI::Auth::Challenge->_new(
        scheme       => 'Bearer',
        header_value => 'Bearer ' . join(', ', @serialized),
        kind         => 'bearer',
        error        => $error,
    );
}

sub custom_challenge {
    my %opts = _options('custom challenge', [qw(scheme params token68)], @_);

    croak 'custom challenge scheme is required' unless exists $opts{scheme};
    _token('custom challenge scheme', $opts{scheme});
    croak 'custom challenge scheme must not be Basic or Bearer'
        if lc($opts{scheme}) eq 'basic' || lc($opts{scheme}) eq 'bearer';

    croak 'custom challenge params and token68 are mutually exclusive'
        if exists $opts{params} && exists $opts{token68};

    my $header_value = $opts{scheme};
    if (exists $opts{params}) {
        my @params = _params('custom challenge params', $opts{params});
        $header_value .= ' ' . join(', ', @params);
    }
    elsif (exists $opts{token68}) {
        _token68('custom challenge token68', $opts{token68});
        $header_value .= ' ' . $opts{token68};
    }

    return PAGI::Auth::Challenge->_new(
        scheme       => $opts{scheme},
        header_value => $header_value,
        kind         => 'custom',
        error        => undef,
    );
}

sub challenge {
    require PAGI::Auth::Outcomes;
    return PAGI::Auth::Outcomes->challenge(@_);
}

sub forbid {
    require PAGI::Auth::Outcomes;
    return PAGI::Auth::Outcomes->forbid(@_);
}

sub _options {
    my ($context, $allowed, @args) = @_;
    croak "$context options must be name/value pairs" if @args % 2;

    my %allowed = map { $_ => 1 } @$allowed;
    my %opts;
    while (@args) {
        my ($name, $value) = splice @args, 0, 2;
        croak "$context option names must be defined scalar strings"
            unless defined($name) && !ref($name);
        croak "unknown $context option '$name'" unless $allowed{$name};
        croak "duplicate $context option '$name'" if exists $opts{$name};
        $opts{$name} = $value;
    }
    return %opts;
}

sub _token {
    my ($name, $value) = @_;
    _scalar($name, $value);
    croak "$name must be an HTTP token"
        unless $value =~ /\A[!#\$%&'*+\-.\^_`|~0-9A-Za-z]+\z/;
    return $value;
}

sub _token68 {
    my ($name, $value) = @_;
    _scalar($name, $value);
    croak "$name must be a nonempty token68"
        unless $value =~ /\A[A-Za-z0-9\-._~+\/]+=*\z/;
    return $value;
}

sub _quoted_value {
    my ($name, $value) = @_;
    _scalar($name, $value);
    croak "$name must contain only printable ASCII"
        unless $value =~ /\A[\x20-\x7E]*\z/;
    return $value;
}

sub _scope {
    my ($name, $value) = @_;
    croak "$name must be an unblessed arrayref"
        unless ref($value) eq 'ARRAY' && !blessed($value);
    croak "$name must not be empty" unless @$value;

    my %seen;
    for my $token (@$value) {
        _scalar("$name token", $token);
        croak "$name tokens must contain only RFC scope characters"
            unless $token =~ /\A[\x21\x23-\x5B\x5D-\x7E]+\z/;
        croak "$name contains duplicate token '$token'" if $seen{$token}++;
    }
    return $value;
}

sub _bearer_printable {
    my ($name, $value) = @_;
    _scalar($name, $value);
    croak "$name must contain only RFC printable characters"
        unless $value =~ /\A[\x20-\x21\x23-\x5B\x5D-\x7E]+\z/;
    return $value;
}

sub _absolute_bearer_uri {
    my ($name, $value) = @_;
    _bearer_printable($name, $value);
    croak "$name must be an absolute URI"
        unless $value =~ /\A[A-Za-z][A-Za-z0-9+.-]*:[\x21-\x7E]*\z/;
    return $value;
}

sub _scalar {
    my ($name, $value) = @_;
    croak "$name must be a defined scalar"
        unless defined($value) && !ref($value);
    return $value;
}

sub _params {
    my ($name, $params) = @_;
    croak "$name must be an unblessed hashref"
        unless ref($params) eq 'HASH' && !blessed($params);
    croak "$name must not be empty" unless keys %$params;

    my %seen;
    for my $key (keys %$params) {
        _token("$name name", $key);
        my $folded = lc $key;
        croak "$name contains duplicate case-insensitive name '$key'"
            if $seen{$folded}++;
        _quoted_value("$name value for '$key'", $params->{$key});
    }

    return map { $_ . '=' . _quote($params->{$_}) }
        sort { lc($a) cmp lc($b) || $a cmp $b } keys %$params;
}

sub _quote {
    my ($value) = @_;
    $value =~ s/([\\"])/\\$1/g;
    return '"' . $value . '"';
}

1;
