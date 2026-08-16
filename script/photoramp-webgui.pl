#!perl
use strict;
use warnings;
use v5.26;

setup();
launch();

#######################################################################

sub setup {
  require App::PhotoRamp;
  our $appdata_dir = $App::PhotoRamp::appdata_dir;
  warn "DEBUG: appdata_dir will be $appdata_dir\n";

  require File::Spec;
  my $install_dir = File::Spec->catfile($appdata_dir, 'webgui_assets');

  unless (-d $install_dir) {
    warn "INFO: Installation directory does not exist. Installing to $install_dir...\n";
    require App::PhotoRamp::WebGUI::Data;
    App::PhotoRamp::WebGUI::Data::install($install_dir);
  }

  $ENV{PHOTORAMP_BASEDIR} = $install_dir;
}

sub launch {
  require App::PhotoRamp::WebGUI::App;
  require HTTP::Server::PSGI;

  my $parent_pid = $$;
  my $in_parent  = my $child_pid = fork();

  die "Unable to fork! $@"
    if !defined $child_pid;

  if ($in_parent) {
    my $server = HTTP::Server::PSGI->new(
      host    => '127.0.0.1',
      port    => 5678,
      timeout => 60,
    );
    $server->run(App::PhotoRamp::WebGUI::App->app);
    exit;
  }

  unless (test_request()) {
    warn "FATAL: Server unreachable, exiting and signalling pid $parent_pid with ABRT\n";
    kill 'ABRT', $parent_pid;
    exit 1;
  }

  # Launch browser
  open_browser('http://localhost:5678');

  my $retries = 0;
  while ($retries < 5) {
    sleep 59;

    my $t = test_request();
    if (!$t) {
      $retries++;
      next;
    }

    if (time - int($t) > 300) {
      warn "DEBUG: Server has been inactive, terminating.\n";
      kill 'TERM', $parent_pid;
      exit;
    }
    $retries = 0;
  }
}

sub open_browser {
  # Windows
  # Linux
  # MacOS
  `$_[0]`;
}

sub test_request {
  require Plack::LWPish;
  require HTTP::Request;
  require HTTP::Response;

  my $req = HTTP::Request->new(GET => 'http://localhost:5678/server-status/last-active');
  my $res = Plack::LWPish->new->request($req); # returns HTTP::Response

  return ($res->is_success and $res->code == 200) ? $res->content : undef;
}
