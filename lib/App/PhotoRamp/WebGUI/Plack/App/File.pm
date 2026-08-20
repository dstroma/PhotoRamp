package App::PhotoRamp::WebGUI::Plack::App::File;
use strict;
use warnings;
use parent qw/Plack::App::File/;
use HTTP::Date;

sub serve_path {
  my $self    = shift;
  my $return  = $self->SUPER::serve_path(@_);
  my $expires = HTTP::Date::time2str(time() + 60*60*24);
  push $return->[1]->@*, 'Expires', $expires;
  use Data::Dumper; warn Dumper $return;
  return $return;
}

1;
