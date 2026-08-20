package App::PhotoRamp::WebGUI::Plack::Middleware::Static;
use strict;
use warnings;
use parent qw/Plack::Middleware/;
use App::PhotoRamp::WebGUI::Plack::App::File;

use Plack::Util::Accessor qw( path root encoding pass_through content_type );

sub call {
    my $self = shift;
    my $env  = shift;

    my $res = $self->_handle_static($env);
    if ($res && not ($self->pass_through and $res->[0] == 404)) {
        return $res;
    }

    return $self->app->($env);
}

sub _handle_static {
    my($self, $env) = @_;

    my $path_match = $self->path or return;
    my $path = $env->{PATH_INFO};

    for ($path) {
        my $matched = 'CODE' eq ref $path_match ? $path_match->($_, $env) : $_ =~ $path_match;
        return unless $matched;
    }

    $self->{file} ||= App::PhotoRamp::WebGUI::Plack::App::File->new({ root => $self->root || '.', encoding => $self->encoding, content_type => $self->content_type });
    local $env->{PATH_INFO} = $path; # rewrite PATH
    return $self->{file}->call($env);
}

1;
__END__

=pod

This is almost an exact duplicate of Plack::Middleware::Static.
Credit where credit is due.
