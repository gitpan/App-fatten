package Perinci::CmdLine::fatten;

our $DATE = '2014-11-14'; # DATE
our $VERSION = '0.16'; # VERSION

use 5.010;
use parent qw(Perinci::CmdLine::Lite);

sub hook_before_read_config_file {
    my ($self, $r) = @_;

    return if defined $r->{config_profile};

    # this is a hack, not proper cmdline arg parsing like in parse_argv().

    my $input_file;
    my $in_args;
    for my $i (0..$#ARGV) {
        my $arg = $ARGV[$i];
        if ($arg eq '--') {
            $in_args++;
            next;
        }
        if ($arg =~ /^-/ && !$in_args) {
            if ($arg =~ /^(-i|--input-file)$/ && $i < $#ARGV) {
                $input_file = $ARGV[$i+1];
                last;
            }
        }
        if ($arg !~ /^-/ || $in_args) {
            $input_file = $arg;
            last;
        }
    }

    return unless defined $input_file;

    require File::Spec;
    my ($vol, $dir, $name) = File::Spec->splitpath($input_file);
    $r->{config_profile} = $name;
    $r->{ignore_missing_config_profile_section} = 1;
}

1;
# ABSTRACT: Subclass of Perinci::CmdLine::Lite to set config_profile default

__END__

=pod

=encoding UTF-8

=head1 NAME

Perinci::CmdLine::fatten - Subclass of Perinci::CmdLine::Lite to set config_profile default

=head1 VERSION

This document describes version 0.16 of Perinci::CmdLine::fatten (from Perl distribution App-fatten), released on 2014-11-14.

=head1 DESCRIPTION

This subclass sets default config_profile to the name of input script, for
convenience.

=head1 HOMEPAGE

Please visit the project's homepage at L<https://metacpan.org/release/App-fatten>.

=head1 SOURCE

Source repository is at L<https://github.com/perlancar/perl-App-fatten>.

=head1 BUGS

Please report any bugs or feature requests on the bugtracker website L<https://rt.cpan.org/Public/Dist/Display.html?Name=App-fatten>

When submitting a bug or request, please include a test-file or a
patch to an existing test-file that illustrates the bug or desired
feature.

=head1 AUTHOR

perlancar <perlancar@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by perlancar@cpan.org.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
