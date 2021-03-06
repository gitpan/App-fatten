package App::fatten;

our $DATE = '2015-01-05'; # DATE
our $VERSION = '0.28'; # VERSION

use 5.010001;
use strict;
use warnings;
use experimental 'smartmatch';
use Log::Any '$log';
BEGIN { no warnings; $main::Log_Level = 'info' }

use App::tracepm;
use Cwd qw(abs_path);
use Dist::Util qw(list_dist_modules);
use File::chdir;
use File::Copy;
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Slurp::Tiny qw(write_file read_file);
use File::Temp qw(tempfile tempdir);
use List::MoreUtils qw(uniq);
use List::Util qw(first);
use Log::Any::For::Builtins qw(system my_qx);
use Module::Path::More qw(module_path);
use Proc::ChildError qw(explain_child_error);
use File::MoreUtil qw(file_exists);
use String::ShellQuote;
use version;

sub _sq { shell_quote($_[0]) }

our %SPEC;

sub _trace {
    my $self = shift;

    $log->debugf("  Tracing with method '%s' ...", $self->{trace_method});
    my $res = App::tracepm::tracepm(
        method => $self->{trace_method},
        script => $self->{input_file},
        args => $self->{args},
        use => $self->{use},
        recurse_exclude_core => $self->{exclude_core} ? 1:0,
        recurse_exclude_xs   => 1,
        detail => 1,

        core => $self->{exclude_core} ? 0 : undef,
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

    my @mods; # modules to add

    my $deps = $self->{deps};
    for (@$deps) {
        next if $_->{is_core} && $self->{exclude_core};
        next if $_->{is_xs};
        $log->debugf("  Adding module: %s (traced)", $_->{module});
        push @mods, $_->{module};
    }

    for (@{ $self->{include} // [] }) {
        $log->debugf("  Adding module: %s (included)", $_);
        push @mods, $_;
    }

    for (@{ $self->{include_dist} // [] }) {
        my @distmods = list_dist_modules($_);
        if (@distmods) {
            $log->debugf("  Adding modules: %s (included dist)", join(", ", @distmods));
            push @mods, @distmods;
        } else {
            $log->debugf("  Adding module: %s (included dist, but can't find other modules)", $_);
            push @mods, $_;
        }
    }

    @mods = uniq(@mods);

    # filter excluded
    my $excluded_distmods;
    my @fmods;
  MOD:
    for my $mod (@mods) {
        if ($self->{exclude} && $mod ~~ @{ $self->{exclude} }) {
            $log->infof("Excluding %s: skipped", $mod);
            next MOD;
        }
        for (@{ $self->{exclude_pattern} // [] }) {
            if ($mod ~~ /$_/) {
                $log->infof("Excluding %s: skipped by pattern %s", $mod, $_);
                next MOD;
            }
        }
        if ($self->{exclude_dist}) {
            if (!$excluded_distmods) {
                $excluded_distmods = [];
                for (@{ $self->{exclude_dist} }) {
                    push @$excluded_distmods, list_dist_modules($_);
                }
            }
            if ($mod ~~ @$excluded_distmods) {
                $log->infof("Excluding %s (by dist): skipped", $mod);
                next MOD;
            }
        }
        push @fmods, $mod;
    }
    @mods = @fmods;

    for my $mod (@mods) {
        my $mpath = module_path(module=>$mod) or die "Can't find path for $mod";

        my $modp = $mod; $modp =~ s!::!/!g; $modp .= ".pm";
        my ($dir) = $modp =~ m!(.+)/(.+)!;
        if ($dir) {
            my $dir_to_make = "$tempdir/lib/$dir";
            unless (-d $dir_to_make) {
                make_path($dir_to_make) or die "Can't make_path: $dir_to_make";
            }
        }

        if ($self->{stripper}) {
            my $stripper = do {
                require Perl::Stripper;
                Perl::Stripper->new(
                    maintain_linum => $self->{stripper_maintain_linum},
                    strip_ws       => $self->{stripper_ws},
                    strip_comment  => $self->{stripper_comment},
                    strip_pod      => $self->{stripper_pod},
                    strip_log      => $self->{stripper_log},
                );
            };
            $log->debug("  Stripping $mpath --> $modp ...");
            my $src = read_file($mpath);
            my $stripped = $stripper->strip($src);
            write_file("$tempdir/lib/$modp", $stripped);
        } elsif ($self->{strip}) {
            require Perl::Strip;
            my $strip = Perl::Strip->new;
            $log->debug("  Stripping $mpath --> $modp ...");
            my $src = read_file($mpath);
            my $stripped = $strip->strip($src);
            write_file("$tempdir/lib/$modp", $stripped);
        } elsif ($self->{squish}) {
            $log->debug("  Squishing $mpath --> $modp ...");
            require Perl::Squish;
            my $squish = Perl::Squish->new;
            $squish->file($mpath, "$tempdir/lib/$modp");
        } else {
            $log->debug("  Copying $mpath --> $tempdir/lib/$modp ...");
            copy($mpath, "$tempdir/lib/$modp");
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

    chmod 0755, $self->{abs_output_file};

    # replace shebang line (which contains perl path used by fatpack) with a
    # default system perl. perhaps make this configurable in the future.
    {
        my $ct = read_file($self->{abs_output_file});
        my $shebang = $self->{shebang} // '#!/usr/bin/perl';
        $shebang = "#!$shebang" unless $shebang =~ /^#!/;
        $shebang =~ s/\R+//g;
        $ct =~ s{\A#!(.+)}{$shebang};
        write_file($self->{abs_output_file}, $ct);
    }

    $log->infof("  Produced %s (%.1f KB)",
                $self->{abs_output_file}, (-s $self->{abs_output_file})/1024);
}

sub new {
    my $class = shift;
    bless { @_ }, $class;
}

my $trace_methods;
{
    my $sch = $App::tracepm::SPEC{tracepm}{args}{method}{schema};
    # XXX should've normalized schema
    if (ref($sch->[1]) eq 'HASH') {
        $trace_methods = $sch->[1]{in};
    } else {
        $trace_methods = $sch->[2];
    }
}

$SPEC{fatten} = {
    v => 1.1,
    summary => 'Pack your dependencies onto your script file',
    args => {
        input_file => {
            summary => 'Path to input file (script to be fatpacked)',
            description => <<'_',

`-` (or if unspecified) means to take from standard input (internally, a
temporary file will be created to handle this).

_
            schema => ['str*'],
            default => '-',
            pos => 0,
            cmdline_aliases => { i=>{} },
            'x.schema.entity' => 'filename',
        },
        output_file => {
            summary => 'Path to output file',
            description => <<'_',

If input is from stdin, then output defaults to stdout. You can also specify
stdout by using `-`.

Otherwise, defaults to `<script>.fatpack` in source directory. If source
directory happens to be unwritable by the script, will try `<script>.fatpack` in
current directory. If that fails too, will die.

_
            schema => ['str*'],
            cmdline_aliases => { o=>{} },
            pos => 1,
            tags => ['category:output'],
            'x.schema.entity' => 'filename',
        },
        include => {
            summary => 'Include extra modules',
            'summary.alt.numnoun.singular' => 'Include an extra module',
            description => <<'_',

When the tracing process fails to include a required module, you can add it
here.

_
            schema => ['array*' => of => 'str*'],
            cmdline_aliases => { I => {} },
            tags => ['category:module-selection'],
            element_completion => sub {
                require Complete::Module;
                my %args = @_;
                Complete::Module::complete_module(word=>$args{word});
            },
            'x.schema.entity' => 'modulename',
        },
        include_dist => {
            summary => 'Include all modules of dist',
            description => <<'_',

Just like the `include` option, but will include module as well as other modules
from the same distribution. Module name must be the main module of the
distribution. Will determine other modules from the `.packlist` file.

_
            schema => ['array*' => of => 'str*'],
            cmdline_aliases => {},
            tags => ['category:module-selection'],
            element_completion => {
            },
            'x.schema.entity' => 'modulename',
        },
        exclude => {
            summary => 'Modules to exclude',
            'summary.alt.numnoun.singular' => 'Exclude a module',
            description => <<'_',

When you don't want to include a module, specify it here.

_
            schema => ['array*' => of => 'str*'],
            cmdline_aliases => { E => {} },
            tags => ['category:module-selection'],
            element_completion => sub {
                require Complete::Module;
                my %args = @_;
                Complete::Module::complete_module(word=>$args{word});
            },
            'x.schema.entity' => 'modulename',
        },
        exclude_pattern => {
            summary => 'Regex patterns of modules to exclude',
            'summary.alt.numnoun.singular' => 'Regex pattern of modules to exclude',
            description => <<'_',

When you don't want to include a pattern of modules, specify it here.

_
            schema => ['array*' => of => 'str*'],
            cmdline_aliases => { p => {} },
            tags => ['category:module-selection'],
            'x.schema.entity' => 'modulename',
        },
        exclude_dist => {
            summary => 'Exclude all modules of dist',
            description => <<'_',

Just like the `exclude` option, but will exclude module as well as other modules
from the same distribution. Module name must be the main module of the
distribution. Will determine other modules from the `.packlist` file.

_
            schema => ['array*' => of => 'str*'],
            cmdline_aliases => {},
            tags => ['category:module-selection'],
            element_completion => sub {
                require Complete::Dist;
                my %args = @_;
                Complete::Dist::complete_dist(word=>$args{word});
            },
            'x.schema.entity' => 'modulename',
        },
        exclude_core => {
            summary => 'Exclude core modules',
            'summary.alt.bool.not' => 'Do not exclude core modules',
            schema => ['bool' => default => 1],
            tags => ['category:module-selection'],
        },
        perl_version => {
            summary => 'Perl version to target, defaults to current running version',
            description => <<'_',

This is for determining which modules are considered core and should be skipped
by default (when `exclude_core` option is enabled). Different perl versions have
different sets of core modules as well as different versions of the modules.

_
            schema => ['str*'],
            cmdline_aliases => { V=>{} },
            # XXX completion: list of known perl versions by Module::CoreList?
        },

        overwrite => {
            schema => [bool => default => 0],
            summary => 'Whether to overwrite output if previously exists',
            tags => ['category:output'],
        },
        trace_method => {
            summary => "Which method to use to trace dependencies",
            schema => ['str*', {
                default => 'fatpacker',
                in=>$trace_methods,
            }],
            description => <<'_',

The default is `fatpacker`, which is the same as what `fatpack trace` does.
Different tracing methods have different pro's and con's, one method might
detect required modules that another method does not, and vice versa. There are
several methods available, please see `App::tracepm` for more details.

_
            cmdline_aliases => { t=>{} },
            tags => ['category:module-selection'],
        },
        use => {
            summary => 'Additional modules to "use"',
            'summary.alt.numnoun.singular' => 'Additional module to "use"',
            schema => ['array*' => of => 'str*'],
            description => <<'_',

Will be passed to the tracer. Will currently only affect the `fatpacker` and
`require` methods (because those methods actually run your script).

_
            tags => ['category:module-selection'],
            element_completion => sub {
                require Complete::Module;
                my %args = @_;
                Complete::Module::complete_module(word=>$args{word});
            },
            'x.schema.entity' => 'modulename',
        },
        args => {
            summary => 'Script arguments',
            'summary.alt.numnoun.singular' => 'Script argument',
            description => <<'_',

Will be used when running your script, e.g. when `trace_method` is `require`.
For example, if your script requires three arguments: `--foo`, `2`, `"bar baz"`
then you can either use:

    % fatten script output --args --foo --args 2 --args "bar baz"

or:

    % fatten script output --args-json '["--foo",2,"bar baz"]'

_
            schema => ['array*' => of => 'str*'],
        },

        shebang => {
            summary => 'Set shebang line/path',
            schema => 'str*',
            default => '/usr/bin/perl',
        },

        squish => {
            summary => 'Whether to squish included modules using Perl::Squish',
            schema => ['bool' => default=>0],
            tags => ['category:stripping'],
        },

        strip => {
            summary => 'Whether to strip included modules using Perl::Strip',
            schema => ['bool' => default=>0],
            tags => ['category:stripping'],
        },

        stripper => {
            summary => 'Whether to strip included modules using Perl::Stripper',
            schema => ['bool' => default=>0],
            tags => ['category:stripping'],
        },
        stripper_maintain_linum => {
            summary => "Set maintain_linum=1 in Perl::Stripper",
            schema => ['bool'],
            default => 0,
            tags => ['category:stripping'],
            description => <<'_',

Only relevant when stripping using Perl::Stripper.

_
        },
        stripper_ws => {
            summary => "Set strip_ws=1 (strip whitespace) in Perl::Stripper",
            'summary.alt.bool.not' => "Set strip_ws=0 (don't strip whitespace) in Perl::Stripper",
            schema => ['bool'],
            default => 1,
            tags => ['category:stripping'],
            description => <<'_',

Only relevant when stripping using Perl::Stripper.

_
        },
        stripper_comment => {
            summary => "Set strip_comment=1 (strip comments) in Perl::Stripper",
            'summary.alt.bool.not' => "Set strip_comment=0 (don't strip comments) in Perl::Stripper",
            schema => ['bool'],
            default => 1,
            description => <<'_',

Only relevant when stripping using Perl::Stripper.

_
            tags => ['category:stripping'],
        },
        stripper_pod => {
            summary => "Set strip_pod=1 (strip POD) in Perl::Stripper",
            'summary.alt.bool.not' => "Set strip_pod=0 (don't strip POD) in Perl::Stripper",
            schema => ['bool'],
            default => 1,
            tags => ['category:stripping'],
            description => <<'_',

Only relevant when stripping using Perl::Stripper.

_
        },
        stripper_log => {
            summary => "Set strip_log=1 (strip log statements) in Perl::Stripper",
            'summary.alt.bool.not' => "Set strip_log=0 (don't strip log statements) in Perl::Stripper",
            schema => ['bool'],
            default => 0,
            tags => ['category:stripping'],
            description => <<'_',

Only relevant when stripping using Perl::Stripper.

_
        },
        # XXX strip_log_levels

        debug_keep_tempdir => {
            summary => 'Keep temporary directory for debugging',
            schema => ['bool' => default=>0],
            tags => ['category:debugging'],
        },
    },
    deps => {
        exec => 'fatpack',
    },
};
sub fatten {
    my %args = @_;
    my $self = __PACKAGE__->new(%args);

    my $tempdir = tempdir(CLEANUP => 0);
    $log->debugf("Created tempdir %s", $tempdir);
    $self->{tempdir} = $tempdir;

    # for convenience of completion in bash, we allow / to separate namespace.
    # we convert it back to :: here.
    for (@{ $self->{exclude} // [] },
         @{ $self->{exclude_dist} // [] },
         @{ $self->{include} // [] },
         @{ $self->{include_dist} // [] },
         @{ $self->{use} // [] },
     ) {
        s!/!::!g;
        s/\.pm\z//;
    }

    # my understanding is that fatlib contains the stuffs beside the pure-perl
    # .pm files, and currently won't pack anyway.
    #mkdir "$tempdir/fatlib";
    mkdir "$tempdir/lib";

    $self->{perl_version} //= $^V;
    $self->{perl_version} = version->parse($self->{perl_version});
    $log->debugf("Will be targetting perl %s", $self->{perl_version});

    if ($self->{input_file} eq '-') {
        $self->{input_file_is_stdin} = 1;
        $self->{input_file} = $self->{abs_input_file} = (tempfile())[1];
        open my($fh), ">", $self->{abs_input_file}
            or return [500, "Can't write temporary input file '$self->{abs_input_file}': $!"];
        local $_; while (<STDIN>) { print $fh $_ }
        $self->{output_file} //= '-';
    } else {
        (-f $self->{input_file})
            or return [500, "No such input file: $self->{input_file}"];
        $self->{abs_input_file} = abs_path($self->{input_file}) or return
            [500, "Can't find absolute path of input file $self->{input_file}"];
    }

    my $output_file;
    {
        $output_file = $self->{output_file};
        if (defined $output_file) {
            if ($output_file eq '-') {
                $self->{output_file_is_stdout} = 1;
                $self->{output_file} = $self->{abs_output_file} = (tempfile())[1];
                last;
            } else {
                return [412, "Output file '$output_file' exists, won't overwrite (see --overwrite)"]
                    if file_exists($output_file) && !$self->{overwrite};
                last if open my($fh), ">", $output_file;
                return [500, "Can't write to output file '$output_file': $!"];
            }
        }

        my ($vol, $dir, $file) = File::Spec->splitpath($self->{input_file});
        my $fh;

        # try <input>.fatpack in the source directory
        $output_file = File::Spec->catpath($vol, $dir, "$file.fatpack");
        return [412, "Output file '$output_file' exists, won't overwrite (see --overwrite)"]
            if file_exists($output_file) && !$self->{overwrite};
        last if open $fh, ">", $output_file;

        # if failed, try <input>.fatpack in the current directory
        $output_file = "$CWD/$file.fatpack";
        return [412, "Output file '$output_file' exists, won't overwrite (see --overwrite)"]
            if file_exists($output_file) && !$self->{overwrite};
        last if open $fh, ">", $output_file;

        # failed too, bail
        return [500, "Can't write $file.fatpack in source- as well as ".
                    "current directory: $!"];
    }
    $self->{output_file} = $output_file;
    $self->{abs_output_file} //= abs_path($output_file) or return
        [500, "Can't find absolute path of output file '$self->{output_file}'"];

    $log->infof("Tracing dependencies ...");
    $self->_trace;

    $log->infof("Building lib/ ...");
    $self->_build_lib;

    $log->infof("Packing ...");
    $self->_pack;

    if ($self->{debug_keep_tempdir}) {
        $log->infof("Keeping tempdir %s for debugging", $tempdir);
    } else {
        $log->debugf("Deleting tempdir %s ...", $tempdir);
        remove_tree($tempdir);
    }

    if ($self->{input_file_is_stdin}) {
        unlink $self->{abs_input_file};
    }
    if ($self->{output_file_is_stdout}) {
        open my($fh), "<", $self->{abs_output_file}
            or return [500, "Can't open temporary output file '$self->{abs_output_file}': $!"];
        local $_; print while <$fh>; close $fh;
        unlink $self->{abs_output_file};
    }

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

This document describes version 0.28 of App::fatten (from Perl distribution App-fatten), released on 2015-01-05.

=head1 SYNOPSIS

This distribution provides command-line utility called L<fatten>.

=head2 TODO

=over

=back

=head1 FUNCTIONS


=head2 fatten(%args) -> [status, msg, result, meta]

Pack your dependencies onto your script file.

Arguments ('*' denotes required arguments):

=over 4

=item * B<args> => I<array[str]>

Script arguments.

Will be used when running your script, e.g. when C<trace_method> is C<require>.
For example, if your script requires three arguments: C<--foo>, C<2>, C<"bar baz">
then you can either use:

 % fatten script output --args --foo --args 2 --args "bar baz"

or:

 % fatten script output --args-json '["--foo",2,"bar baz"]'

=item * B<debug_keep_tempdir> => I<bool> (default: 0)

Keep temporary directory for debugging.

=item * B<exclude> => I<array[str]>

Modules to exclude.

When you don't want to include a module, specify it here.

=item * B<exclude_core> => I<bool> (default: 1)

Exclude core modules.

=item * B<exclude_dist> => I<array[str]>

Exclude all modules of dist.

Just like the C<exclude> option, but will exclude module as well as other modules
from the same distribution. Module name must be the main module of the
distribution. Will determine other modules from the C<.packlist> file.

=item * B<exclude_pattern> => I<array[str]>

Regex patterns of modules to exclude.

When you don't want to include a pattern of modules, specify it here.

=item * B<include> => I<array[str]>

Include extra modules.

When the tracing process fails to include a required module, you can add it
here.

=item * B<include_dist> => I<array[str]>

Include all modules of dist.

Just like the C<include> option, but will include module as well as other modules
from the same distribution. Module name must be the main module of the
distribution. Will determine other modules from the C<.packlist> file.

=item * B<input_file> => I<str> (default: "-")

Path to input file (script to be fatpacked).

C<-> (or if unspecified) means to take from standard input (internally, a
temporary file will be created to handle this).

=item * B<output_file> => I<str>

Path to output file.

If input is from stdin, then output defaults to stdout. You can also specify
stdout by using C<->.

Otherwise, defaults to C<< E<lt>scriptE<gt>.fatpack >> in source directory. If source
directory happens to be unwritable by the script, will try C<< E<lt>scriptE<gt>.fatpack >> in
current directory. If that fails too, will die.

=item * B<overwrite> => I<bool> (default: 0)

Whether to overwrite output if previously exists.

=item * B<perl_version> => I<str>

Perl version to target, defaults to current running version.

This is for determining which modules are considered core and should be skipped
by default (when C<exclude_core> option is enabled). Different perl versions have
different sets of core modules as well as different versions of the modules.

=item * B<shebang> => I<str> (default: "/usr/bin/perl")

Set shebang line/path.

=item * B<squish> => I<bool> (default: 0)

Whether to squish included modules using Perl::Squish.

=item * B<strip> => I<bool> (default: 0)

Whether to strip included modules using Perl::Strip.

=item * B<stripper> => I<bool> (default: 0)

Whether to strip included modules using Perl::Stripper.

=item * B<stripper_comment> => I<bool> (default: 1)

Set strip_comment=1 (strip comments) in Perl::Stripper.

Only relevant when stripping using Perl::Stripper.

=item * B<stripper_log> => I<bool> (default: 0)

Set strip_log=1 (strip log statements) in Perl::Stripper.

Only relevant when stripping using Perl::Stripper.

=item * B<stripper_maintain_linum> => I<bool> (default: 0)

Set maintain_linum=1 in Perl::Stripper.

Only relevant when stripping using Perl::Stripper.

=item * B<stripper_pod> => I<bool> (default: 1)

Set strip_pod=1 (strip POD) in Perl::Stripper.

Only relevant when stripping using Perl::Stripper.

=item * B<stripper_ws> => I<bool> (default: 1)

Set strip_ws=1 (strip whitespace) in Perl::Stripper.

Only relevant when stripping using Perl::Stripper.

=item * B<trace_method> => I<str> (default: "fatpacker")

Which method to use to trace dependencies.

The default is C<fatpacker>, which is the same as what C<fatpack trace> does.
Different tracing methods have different pro's and con's, one method might
detect required modules that another method does not, and vice versa. There are
several methods available, please see C<App::tracepm> for more details.

=item * B<use> => I<array[str]>

Additional modules to "use".

Will be passed to the tracer. Will currently only affect the C<fatpacker> and
C<require> methods (because those methods actually run your script).

=back

Returns an enveloped result (an array).

First element (status) is an integer containing HTTP status code
(200 means OK, 4xx caller error, 5xx function error). Second element
(msg) is a string containing error message, or 'OK' if status is
200. Third element (result) is optional, the actual result. Fourth
element (meta) is called result metadata and is optional, a hash
that contains extra information.

Return value:  (any)

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

perlancar <perlancar@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by perlancar@cpan.org.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
