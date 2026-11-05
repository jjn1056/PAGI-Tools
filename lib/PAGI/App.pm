package PAGI::App;

use strict;
use warnings;
use Carp ();
use Class::Tiny;

# The application: called with ($scope, $receive, $send), returning a Future.
sub call {
    my ($self) = @_;
    Carp::croak(ref($self) . ' must implement "call" or override "to_app"');
}

# The object as a PAGI application: the stand-in for a callable object.
sub to_app {
    my ($self) = @_;
    return sub { $self->call(@_) };
}

1;

__END__

=head1 NAME

PAGI::App - The base class for a PAGI application object

=head1 SYNOPSIS

    package MyApp;
    use strict;
    use warnings;
    use parent 'PAGI::App';
    use Class::Tiny { greeting => 'Hello' };
    use Future::AsyncAwait;

    async sub call {
        my ($self, $scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200,
                        headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => $self->greeting, more => 0 });
    }

    # elsewhere
    my $app = MyApp->new(greeting => 'Hi')->to_app;   # a PAGI application

=head1 INHERITANCE

    PAGI::App
      Class::Tiny::Object

C<PAGI::App> is a L<Class::Tiny> class: its constructor, C<new>, comes from
C<Class::Tiny::Object>.

=head1 DESCRIPTION

An application object: a class whose instances are PAGI applications. A
subclass writes C<call>, the application, or overrides C<to_app> to return a
whole application of its own.

The base is optional. Anything with a C<to_app> that returns a PAGI
application is an application, whatever its class; nothing checks for this
one.

=head1 METHODS

=head2 new

    my $app = MyApp->new(%args);
    my $app = MyApp->new(\%args);

L<Class::Tiny>'s constructor. The arguments, as a list or one hashref, set
the attributes a class declares (C<< use Class::Tiny qw(name) >>, or with
defaults, C<< use Class::Tiny { name => 'nobody' } >>). A default may be a code
reference, run on first use with the object as its argument, so a setting can
come from C<%ENV> or a configuration file. Undeclared arguments are ignored.
C<BUILDARGS> reshapes the arguments and C<BUILD> validates, parent first.

=head2 call

    async sub call { my ($self, $scope, $receive, $send) = @_; ... }

The application. The default croaks: a subclass must write it, or override
C<to_app>.

=head2 to_app

    my $code = $app->to_app;

Returns the PAGI application: a code reference that calls
C<< $app->call($scope, $receive, $send) >>.

=head1 SEE ALSO

L<PAGI::Spec>, L<Class::Tiny>

=cut
