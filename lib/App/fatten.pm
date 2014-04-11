package App::fatten;

use 5.010001;
use strict;
use warnings;
use experimental 'smartmatch';
use Log::Any '$log';
BEGIN { no warnings; $main::Log_Level = 'info' }

use App::tracepm;
use Cwd qw(abs_path);
use File::chdir;
use File::Copy;
use File::Path qw(make_path remove_tree);
use File::Slurp::Shortcuts qw(slurp slurp_c write_file);
use File::Temp qw(tempfile tempdir);
use List::Util qw(first);
use Log::Any::For::Builtins qw(system my_qx);
use Module::Path qw(module_path);
#use SHARYANTO::Dist::Util qw(packlist_for);
use SHARYANTO::Proc::ChildError qw(explain_child_error);
use String::ShellQuote;
use version;

sub _sq { shell_quote($_[0]) }

our $VERSION = '0.03'; # VERSION

our %SPEC;

sub _trace {
    my $self = shift;

    my $res = App::tracepm::tracepm(
        method => $self->{trace_method},
        script => $self->{input_file},
        use => $self->{use},
        recurse_exclude_core => 1,
        recurse_exclude_xs   => 1,
        detail => 1,

        core => 0,
        xs   => 0,
    );
    die "Can't trace: $res->[0] - $res->[1]" unless $res->[0] == 200;
    $self->{deps} = $res->[2];
}

sub _build_lib {
    my $self = shift;

    my $tempdir = $self->{tempdir};

    my $totsize = 0;
    my $totfiles = 0;

    local $CWD = "$tempdir/lib";

    my @mods; # modules to add

    my $deps = $self->{deps};
    push @mods, (map {$_->{module}} grep {!$_->{is_core} && !$_->{is_xs}} @$deps);

    push @mods, @{ $self->{include} // [] };

    # filter excluded
    my @fmods;
  MOD:
    for my $mod (@mods) {
        if ($self->{exclude} && $mod ~~ @{ $self->{exclude} }) {
            $log->infof("Excluding %s: skipped", $mod);
            next;
        }
        for (@{ $self->{exclude_pattern} // [] }) {
            if ($mod ~~ /$_/) {
                $log->infof("Excluding %s: skipped by pattern %s", $mod, $_);
                next MOD;
            }
        }
        push @fmods, $mod;
    }
    @mods = @fmods;

    for my $mod (@mods) {
        my $mpath = module_path($mod) or die "Can't find path for $mod";

        my $modp = $mod; $modp =~ s!::!/!g; $modp .= ".pm";
        my ($dir) = $modp =~ m!(.+)/(.+)!;
        if ($dir) {
            make_path($dir) unless -d $dir;
        }

        if ($self->{strip}) {
            state $stripper = do {
                require Perl::Stripper;
                Perl::Stripper->new;
            };
            $log->debug("  Stripping $mpath --> $mod ...");
            my $src = slurp($mpath);
            my $stripped = $stripper->strip($src);
            write_file($modp, $stripped);
        } else {
            $log->debug("  Copying $mpath --> $mod ...");
            copy($mpath, $modp);
        }

        $totfiles++;
        $totsize += (-s $mpath);
    }
    $log->infof("  Added %d files (%.1f KB)", $totfiles, $totsize/1024);
}

sub _pack {
    my $self = shift;

    my $tempdir = $self->{tempdir};

    local $CWD = $tempdir;
    system join(
        "",
        "fatpack file ",
        _sq($self->{abs_input_file}), " > ",
        _sq($self->{abs_output_file}),
    );
    die "Can't fatpack file: ".explain_child_error() if $?;
    $log->infof("  Produced %s (%.1f KB)",
                $self->{abs_output_file}, (-s $self->{abs_output_file})/1024);
}

sub new {
    my $class = shift;
    bless { @_ }, $class;
}

$SPEC{fatten} = {
    v => 1.1,
    args => {
        input_file => {
            summary => 'Path to input file (script to be packed)',
            schema => ['str*'],
            req => 1,
            pos => 0,
            cmdline_aliases => { i=>{} },
        },
        output_file => {
            summary => 'Path to output file, defaults to `packed` in current directory',
            schema => ['str*'],
            cmdline_aliases => { o=>{} },
            pos => 1,
        },
        include => {
            summary => 'Modules to include',
            description => <<'_',

When the tracing process fails to include a required module, you can add it
here.

_
            schema => ['array*' => of => 'str*'],
            cmdline_aliases => { I => {} },
        },
        exclude => {
            summary => 'Modules to exclude',
            description => <<'_',

When you don't want to include a module, specify it here.

_
            schema => ['array*' => of => 'str*'],
            cmdline_aliases => { E => {} },
        },
        exclude_pattern => {
            summary => 'Regex patterns of modules to exclude',
            description => <<'_',

When you don't want to include a pattern of modules, specify it here.

_
            schema => ['array*' => of => 'str*'],
            cmdline_aliases => { p => {} },
        },
        perl_version => {
            summary => 'Perl version to target, defaults to current running version',
            schema => ['str*'],
            cmdline_aliases => { V=>{} },
        },
        #overwrite => {
        #    schema => [bool => default => 0],
        #    summary => 'Whether to overwrite output if previously exists',
        #},
        trace_method => {
            summary => "Which method to use to trace dependencies",
            schema => ['str*', default => 'fatpacker'],
            description => <<'_',

The default is `fatpacker`, which is the same as what `fatpack trace` does.
There are other methods available, please see `App::tracepm` for more details.

_
        },
        use => {
            summary => 'Additional modules to "use"',
            schema => ['array*' => of => 'str*'],
            description => <<'_',

Will be passed to the tracer. Will currently only affect the `fatpacker` and
`require` methods (because those methods actually run your script).

_
        },
        strip => {
            summary => 'Whether to strip included modules using Perl::Stripper',
            schema => ['bool' => default=>0],
            cmdline_aliases => { s=>{} },
        },
        # XXX strip_opts
    },
    deps => {
        exec => 'fatpack',
    },
};
sub fatten {
    my %args = @_;
    my $self = __PACKAGE__->new(%args);

    my $tempdir = tempdir(CLEANUP => 1);
    $log->debugf("Created tempdir %s", $tempdir);
    $self->{tempdir} = $tempdir;

    # my understanding is that fatlib contains the stuffs beside the pure-perl
    # .pm files, and currently won't pack anyway.
    #mkdir "$tempdir/fatlib";
    mkdir "$tempdir/lib";

    $self->{perl_version} //= $^V;
    $self->{perl_version} = version->parse($self->{perl_version});
    $log->debugf("Will be targetting perl %s", $self->{perl_version});

    (-f $self->{input_file}) or die "No such input file: $self->{input_file}";
    $self->{abs_input_file} = abs_path($self->{input_file})
        or die "Can't find absolute path of input file $self->{input_file}";

    $self->{output_file} //= "$CWD/packed";
    $self->{abs_output_file} = abs_path($self->{output_file})
        or die "Can't find absolute path of output file $self->{output_file}";

    $log->infof("Tracing dependencies ...");
    $self->_trace;

    $log->infof("Building lib/ ...");
    $self->_build_lib;

    $log->infof("Packing ...");
    $self->_pack;

    [200];
}

1;
# ABSTRACT: Pack your dependencies onto your script file

__END__

=pod

=encoding UTF-8

=head1 NAME

App::fatten - Pack your dependencies onto your script file

=head1 VERSION

version 0.03

=head1 SYNOPSIS

This distribution provides command-line utility called L<fatten>.

=head1 FUNCTIONS


=head2 fatten(%args) -> [status, msg, result, meta]

Arguments ('*' denotes required arguments):

=over 4

=item * B<exclude> => I<array>

Modules to exclude.

When you don't want to include a module, specify it here.

=item * B<exclude_pattern> => I<array>

Regex patterns of modules to exclude.

When you don't want to include a pattern of modules, specify it here.

=item * B<include> => I<array>

Modules to include.

When the tracing process fails to include a required module, you can add it
here.

=item * B<input_file>* => I<str>

Path to input file (script to be packed).

=item * B<output_file> => I<str>

Path to output file, defaults to `packed` in current directory.

=item * B<perl_version> => I<str>

Perl version to target, defaults to current running version.

=item * B<strip> => I<bool> (default: 0)

Whether to strip included modules using Perl::Stripper.

=item * B<trace_method> => I<str> (default: "fatpacker")

Which method to use to trace dependencies.

The default is C<fatpacker>, which is the same as what C<fatpack trace> does.
There are other methods available, please see C<App::tracepm> for more details.

=item * B<use> => I<array>

Additional modules to "use".

Will be passed to the tracer. Will currently only affect the C<fatpacker> and
C<require> methods (because those methods actually run your script).

=back

Return value:

Returns an enveloped result (an array).

First element (status) is an integer containing HTTP status code
(200 means OK, 4xx caller error, 5xx function error). Second element
(msg) is a string containing error message, or 'OK' if status is
200. Third element (result) is optional, the actual result. Fourth
element (meta) is called result metadata and is optional, a hash
that contains extra information.

=for Pod::Coverage ^(new)$

=head1 HOMEPAGE

Please visit the project's homepage at L<https://metacpan.org/release/App-fatten>.

=head1 SOURCE

Source repository is at L<https://github.com/sharyanto/perl-App-fatten>.

=head1 BUGS

Please report any bugs or feature requests on the bugtracker website L<https://rt.cpan.org/Public/Dist/Display.html?Name=App-fatten>

When submitting a bug or request, please include a test-file or a
patch to an existing test-file that illustrates the bug or desired
feature.

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
