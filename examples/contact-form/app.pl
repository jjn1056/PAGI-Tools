#!/usr/bin/env perl
use strict;
use warnings;

use Future::AsyncAwait;
use File::Basename qw(dirname);
use File::Spec;

use PAGI::App::File;
use PAGI::Compose qw(compose);
use PAGI::Response qw(response);
use PAGI::Routing qw(route);

# Writable uploads keep an explicit path beside this file; only the read-only
# public/ directory uses the application-relative file constructor.
my $UPLOAD_DIR = File::Spec->catdir(dirname(__FILE__), 'uploads');

# Allowed MIME types for attachments
my %ALLOWED_TYPES = (
    'application/pdf' => 'pdf',
    'image/jpeg'      => 'jpg',
    'image/png'       => 'png',
    'image/gif'       => 'gif',
    'text/plain'      => 'txt',
);

# POST /submit: one PAGI::Request in, one JSON Response out.
async sub submit {
    my ($req) = @_;

    # 5MB per-file limit; applies to the whole multipart parse (uploads included)
    my $form = await $req->form_params(max_file_size => 5 * 1024 * 1024);
    my @errors;

    # Validate required fields
    my $name = $form->get('name') // '';
    my $email = $form->get('email') // '';
    my $message = $form->get('message') // '';
    my $subject = $form->get('subject') // 'general';
    my $subscribe = $form->get('subscribe') // '';

    push @errors, 'Name is required' unless length $name;
    push @errors, 'Email is required' unless length $email;
    push @errors, 'Invalid email format' unless $email =~ /@/;
    push @errors, 'Message is required' unless length $message;

    # Handle file upload
    my $attachment = await $req->upload('attachment');
    my $saved_file;

    if ($attachment && !$attachment->is_empty) {
        my $ct = $attachment->content_type;
        my $size = $attachment->size;

        # Validate type
        unless (exists $ALLOWED_TYPES{$ct}) {
            push @errors, "File type not allowed: $ct";
        }

        # Validate size (already enforced by Request, but double-check)
        if ($size > 5 * 1024 * 1024) {
            push @errors, "File too large (max 5MB)";
        }

        # Save file if valid
        unless (@errors) {
            my $ext = $ALLOWED_TYPES{$ct} // 'bin';
            my $safe_name = time() . '-' . int(rand(10000)) . ".$ext";
            my $dest = "$UPLOAD_DIR/$safe_name";

            my $save_ok = eval {
                $attachment->move_to($dest);
                1;
            };
            if ($save_ok) {
                $saved_file = $safe_name;
            } else {
                push @errors, "Failed to save file: $@";
            }
        }
    }

    # Return errors if any
    if (@errors) {
        return response('JSON', {
            success => 0,
            errors  => \@errors,
        }, status => 400);
    }

    # Success response
    return response('JSON', {
        success => 1,
        message => 'Thank you for your message!',
        data    => {
            name      => $name,
            email     => $email,
            subject   => $subject,
            message   => substr($message, 0, 100) . (length($message) > 100 ? '...' : ''),
            subscribe => ($subscribe eq 'yes' ? 1 : 0),
            attachment => $saved_file,
        },
    });
}

compose(
    routes => [
        route('/submit' => \&submit, methods => ['POST']),
        route('/*path' => PAGI::App::File->from_app_path('public')),
    ],
    lifespan => {
        startup => async sub {
            mkdir $UPLOAD_DIR unless -d $UPLOAD_DIR;
            print STDERR "[lifespan] Contact form app started\n";
            print STDERR "[lifespan] Upload directory: $UPLOAD_DIR\n";
        },
        shutdown => async sub {
            print STDERR "[lifespan] Shutting down\n";
        },
    },
);

__END__

=head1 NAME

Contact Form Example - PAGI::Request Demo

=head1 SYNOPSIS

    pagi-server --app examples/contact-form/app.pl --port 5000

Then visit http://localhost:5000/

=head1 DESCRIPTION

Demonstrates PAGI::Request features:

=over

=item * Form parsing with validation

=item * File upload handling

=item * Content-type validation

=item * JSON responses

=back

=cut
