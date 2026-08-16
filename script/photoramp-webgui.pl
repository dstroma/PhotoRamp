#!perl
use strict;
use warnings;
use v5.26;

my ($appdata_dir, $log_file);
setup();
launch();

#######################################################################

sub setup {
  require App::PhotoRamp;
  { no warnings 'once';
    $appdata_dir = $App::PhotoRamp::appdata_dir;
  }
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
  #require HTTP::Server::PSGI;
  require Plack::Handler::Starlet;

  my $parent_pid = $$;
  my $in_parent  = my $child_pid = fork();

  die "Unable to fork! $@"
    if !defined $child_pid;

  $0 = $in_parent ? 'PhotoRamp WebGUI Server' : 'PhotoRamp WebGUI Monitor';

  if ($in_parent) {
    #my $server = HTTP::Server::PSGI->new(
    #  host    => '127.0.0.1',
    #  port    => 5678,
    #  timeout => 60,
    #);
    my $server = Plack::Handler::Starlet->new(
      host    => '127.0.0.1',
      port    => 5678,
      keepalive_timeout => 1,
      max_keepalive_requests => 10,
      max_workers => 4
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

  # Monitor
  { no warnings 'once';
    $log_file = $App::PhotoRamp::WebGUI::App::server_logfile;
  }
  while (1) {
    my $t = [stat($log_file)]->[9];
    if (time - $t > 300) {
      warn "DEBUG: Server has been inactive as of " . time() . ", terminating.\n";
      kill 'TERM', $parent_pid;
      exit;
    }
    sleep 60;
  }
}

sub open_browser {
  # Windows
  # Linux
  # MacOS
  `open $_[0]`;
}

sub test_request {
  require Plack::LWPish;
  require HTTP::Request;
  require HTTP::Response;

  my $req = HTTP::Request->new(GET => 'http://localhost:5678/check-alive');
  my $res = Plack::LWPish->new->request($req); # returns HTTP::Response

  return ($res->is_success and $res->code == 200 and $res->content =~ m/OK/) ? 1 : undef;
}
