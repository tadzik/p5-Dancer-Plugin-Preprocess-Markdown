package Dancer::Plugin::Preprocess::Markdown;

use strict;
use warnings;

# ABSTRACT: Generate HTML content from Markdown files

# VERSION

use Cwd 'abs_path';
use Dancer ':syntax';
use Dancer::Plugin;
use File::Spec::Functions qw(catfile file_name_is_absolute);
use Text::Markdown qw(markdown);

my $settings = {
    save => 0,
    # TODO: It might make more sense to have 1 as the default
    recursive => 0,
    %{plugin_setting()}
};
my $paths;

if (exists $settings->{paths}) {
    $paths = $settings->{paths};
}

my $paths_re = join '|', map {
    s{^[^/]}{/$0};      # Add leading slash, if missing
    s{/$}{};            # Remove trailing slash
    quotemeta;
} reverse sort keys %$paths;

sub _process_markdown_file {
    my $md_file = shift;

    open (my $f, '<', $md_file);
    my $contents;
    {
        local $/;
        $contents = <$f>;
    }
    close($f);

    return markdown($contents);
}

my $handler_defined;

# Postpone setting up the route handler to the time before the first request is
# processed, so that other routes defined in the app will take precedence.
hook on_reset_state => sub {
    return if $handler_defined;

    get qr{($paths_re)/(.*)} => sub {
        my ($path, $file) = splat;

        $path .= '/';
        my $path_settings;

        for my $path_prefix (reverse sort keys %$paths) {
            (my $path_prefix_slash = $path_prefix) =~ s{([^/])$}{$1/};

            if (substr($path, 0, length($path_prefix_slash)) eq
                $path_prefix_slash)
            {
                # Found a matching path
                $path_settings = {
                    # Top-level settings
                    save => $settings->{save},
                    recursive => $settings->{recursive},
                    # Path-specific settings (may override top-level ones)
                    %{$paths->{$path_prefix} || {}}
                };
                last;
            }
        }

        # Pass if there was no matching path
        return pass if (!defined $path_settings);

        # Pass if the requested file appears to be in a subdirectory while
        # recursive mode is off
        return pass if (!$path_settings->{recursive} && $file =~ m{/});

        if (!exists $path_settings->{src_dir}) {
            # Source directory not specified -- use default
            $path_settings->{src_dir} = path 'md', 'src', split(m{/}, $path);
        }

        # Strip off the ".html" suffix, if present
        $file =~ s/\.html$//;

        my $src_file;

        if (file_name_is_absolute($path_settings->{src_dir})) {
            $src_file = path $path_settings->{src_dir}, ($file . '.md');
        }
        else {
            # Assume a non-absolute source directory is relative to appdir
            $src_file = path abs_path(setting('appdir')),
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
                $content = _process_markdown_file($src_file);

                open(my $f, '>', $dest_file);
                # TODO: Error handling
                print {$f} $content;
                close($f);
            }
            else {
                # The HTML file already exists -- read its contents back to the
                # client
                open (my $f, '<', $dest_file);
                # TODO: Error handling
                {
                    local $/;
                    $content = <$f>;
                }
                close($f);
            }
        }
        else {
            $content = _process_markdown_file($src_file); 
        }

        # TODO: Add support for path-specific layouts
        return (engine 'template')->apply_layout($content);
    };

    $handler_defined = 1;
};

register_plugin;

1;

__END__

=head1 SYNOPSIS

Dancer::Plugin::Preprocess::Markdown automatically generates HTML content from
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

=head1 DESCRIPTION

Dancer::Plugin::Preprocess::Markdown generates HTML content from Markdown source
files.

When an HTML file is requested, and its path matches one of the paths specified
in the configuration, the plugin looks for a corresponding Markdown file and
processes it to produce the HTML content. The generated HTML file may then be
saved and re-used with subsequent requests for the same URL.

=head1 CONFIGURATION

The available configuration settings are described below.

=head2 Top-level settings

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