package Dancer2::Plugin::Preprocess::Markdown;
use Dancer2::Plugin;
use strict;
use warnings;

# ABSTRACT: Generate HTML content from Markdown files

# VERSION

use Cwd 'abs_path';
use File::Spec::Functions qw(catfile file_name_is_absolute);
use Text::Markdown qw(markdown);
use Path::Tiny;

has layout           => (is => 'ro', from_config => sub { undef });
has markdown_options => (is => 'ro', from_config => sub {  {}   });
has recursive        => (is => 'ro', from_config => sub {   0   });
has save             => (is => 'ro', from_config => sub {   0   });
has paths            => (is => 'ro', from_config => sub { undef });
has paths_re         => (is => 'ro');

sub BUILD {
    my $self = shift;
    $self->{paths_re} = join '|', map {
        my $s = $_;
        $s =~ s{^[^/]}{/$&};    # Add leading slash, if missing
        $s =~ s{/$}{};          # Remove trailing slash
        quotemeta $s;
    } reverse sort keys %{$self->paths};

    $self->app->add_hook(Dancer2::Core::Hook->new(
        name => 'before',
        code => sub { $self->markdown_hook(shift) },
    ));
}

sub _process_markdown_file {
    my ($md_file, $md_options) = @_;

    open (my $f, '<', $md_file);
    my $contents;
    {
        local $/;
        $contents = <$f>;
    }
    close($f);

    return markdown($contents, $md_options);
}

# Postpone setting up the route handler to the time before the first request is
# processed, so that other routes defined in the app will take precedence.
sub markdown_hook {
    my ($self, $app) = @_;
    my $re = qr{($self->{paths_re})/(.*)};
    $app->add_route(method => 'get', regexp => $re, code => sub {
        my $app = shift;
        my ($path, $file) = $app->request->splat;

        $path .= '/';
        my $path_settings;

        for my $path_prefix (reverse sort keys %{$self->paths}) {
            (my $path_prefix_slash = $path_prefix) =~ s{([^/])$}{$1/};

            if (substr($path, 0, length($path_prefix_slash)) eq
                $path_prefix_slash)
            {
                # Found a matching path
                $path_settings = {
                    # Top-level settings
                    layout           => $self->layout,
                    markdown_options => $self->markdown_options,
                    recursive        => $self->recursive,
                    save             => $self->save,
                    # Path-specific settings (may override top-level ones)
                    %{$self->paths->{$path_prefix} || {}}
                };
                last;
            }
        }

        # Pass if there was no matching path
        return $app->pass if (!defined $path_settings);

        # Pass if the requested file appears to be in a subdirectory while
        # recursive mode is off
        return $app->pass if (!$path_settings->{recursive} && $file =~ m{/});

        if (!exists $path_settings->{src_dir}) {
            # Source directory not specified -- use default
            $path_settings->{src_dir} = path 'md', 'src', grep { $_ } split(m{/}, $path);
        }

        # Strip off the ".html" suffix, if present
        $file =~ s/\.html$//;

        my $src_file;

        if (file_name_is_absolute($path_settings->{src_dir})) {
            $src_file = path $path_settings->{src_dir}, ($file . '.md');
        }
        else {
            # Assume a non-absolute source directory is relative to appdir
            $src_file = path abs_path($app->setting('appdir')),
                $path_settings->{src_dir}, ($file . '.md');
        }

        if (!-r $src_file) {
            return send_error("Not allowed", 403);
        }

        my $content;

        if ($path_settings->{save}) {
            if (!exists $path_settings->{dest_dir}) {
                $path_settings->{dest_dir} = path 'md', 'dest',
                    split(m{/}, $path);
            }

            my $dest_file;

            if (file_name_is_absolute($path_settings->{dest_dir})) {
                $dest_file = path $path_settings->{dest_dir}, ($file . '.html');
            }
            else {
                # Assume a non-absolute destination directory is relative to
                # appdir
                $dest_file = path abs_path(setting('appdir')),
                    $path_settings->{dest_dir}, ($file . '.html');
            }

            if (!-f $dest_file ||
                ((stat($dest_file))[9] < (stat($src_file))[9]))
            {
                # Source file is newer than destination file (or the latter does
                # not exist)
                $content = _process_markdown_file($src_file,
                    $path_settings->{markdown_options});

                if (open(my $f, '>', $dest_file)) {
                    print {$f} $content;
                    close($f);
                }
                else {
                    $app->log->(warning => __PACKAGE__ .
                        ": Can't open '$dest_file' for writing");
                }
            }
            else {
                # The HTML file already exists -- read its contents back to the
                # client
                if (open (my $f, '<', $dest_file)) {
                    local $/;
                    $content = <$f>;
                    close($f);
                }
                else {
                    $app->log->(warning => __PACKAGE__ .
                        ": Can't open '$dest_file' for reading");
                }
            }
        }

        if (!defined $content) {
            $content = _process_markdown_file($src_file,
                $path_settings->{markdown_options}); 
        }

        # TODO: Add support for path-specific layouts
        return $app->engine('template')->apply_layout($content, {},
            { layout => $path_settings->{layout} });
    });
};

1;

__END__

=head1 SYNOPSIS

Dancer2::Plugin::Preprocess::Markdown automatically generates HTML content from
Markdown files in a Dancer web application.

Add the plugin to your application:

    use Dancer::Plugin::Preprocess::Markdown;

Configure its settings in the YAML configuration file:

    plugins:
      "Preprocess::Markdown":
        save: 1
        paths:
          "/documents":
            recursive: 1
            save: 0
          "/articles":
            src_dir: "articles/markdown"
            dest_dir: "articles/html"
            layout: "article"

=head1 DESCRIPTION

Dancer2::Plugin::Preprocess::Markdown generates HTML content from Markdown source
files.

When an HTML file is requested, and its path matches one of the paths specified
in the configuration, the plugin looks for a corresponding Markdown file and
processes it to produce the HTML content. The generated HTML file may then be
saved and re-used with subsequent requests for the same URL.

=head1 CONFIGURATION

The available configuration settings are described below.

=head2 Top-level settings

=head3 layout

The layout used to display the generated HTML content.

=head3 markdown_options

The options to be passed to the markdown processing subroutine of
L<Text::Markdown> (see Text::Markdown documentation for the list of available
options).

=head3 paths

A collection of paths that will be served by the plugin. Each path entry may
define path-specific settings that override top-level settings.

=head3 recursive

If set to C<0>, then the plugin only processes files placed in the source
directory and not its subdirectories. If set to C<1>, subdirectories are also
processed.

Default: C<0>

=head3 save

If set to C<0>, then the HTML content is generated on-the-fly with every
request. If set to C<1>, then HTML files are generated once and saved, and are
used in subsequent responses. The files are regenerated every time the source
Markdown files are modified.

Default: C<0>

=head2 Path-specific settings

=head3 src_dir

The directory where source Markdown files are located.

Default: C<md/src/I<{path}>>

=head3 dest_dir

The destination directory for the generated HTML files (if the C<save> option is
in use).

Default: C<md/dest/I<{path}>>

=head1 ROUTE HANDLERS VS. PATHS

If there's a route defined in your application that matches one of the paths
served by the plugin, it will take precedence. For example, with the following
configuration:

    plugins:
      "Preprocess::Markdown":
        paths:
          "/documents":
            ...

and this route in the application:

    get '/documents/faq' => sub {
        ...
    };

A request for C</documents/faq> won't be processed by the plugin, but by the
handler defined in the application.

=head1 SEE ALSO

=for :list
* L<Text::Markdown>
* L<Markdown Homepage|http://daringfireball.net/projects/markdown/>

=head1 ACKNOWLEDGEMENTS

Markdown to HTML conversion is done with L<Text::Markdown>, written by Tomas
Doran.

=cut
