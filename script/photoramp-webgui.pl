#!perl
use strict;
use warnings;
use v5.26;
use experimental 'signatures';
use File::Spec::Functions qw(catfile catdir);
use File::Path qw(make_path remove_tree);

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

  my $install_dir = catfile($appdata_dir, 'webgui_assets');

  unless (-d $install_dir) {
    warn "INFO: Installation directory does not exist. Installing to $install_dir...\n";
    require App::PhotoRamp::WebGUI::Data;
    App::PhotoRamp::WebGUI::Data::install($install_dir);
  }

  $ENV{PHOTORAMP_BASEDIR} = $install_dir;
}

sub launch {
  require App::PhotoRamp::WebGUI::App;
  my $server_class;
  foreach my $sc ('Plack::Handler::Starlet', 'HTTP::Server::PSGI') {
    if (eval "require $sc; 1") {
      $server_class = $sc;
      last;
    }
  }
  $server_class or die "No server module available!";

  my $parent_pid = $$;
  my $in_parent  = my $child_pid = fork();

  die "Unable to fork! $@"
    if !defined $child_pid;

  $0 = $in_parent ? 'PhotoRamp WebGUI Server' : 'PhotoRamp WebGUI Monitor';

  if ($in_parent) {
    my $server = $server_class->new(
      host    => '127.0.0.1',
      port    => 5678,
      timeout => 60,
      (
        $server_class =~ m/Starlet/ ? (
          keepalive_timeout => 1,
          max_keepalive_requests => 100,
          max_workers => 4,
        ) : ()
      )
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
  my $browser_pid = open_browser("http://localhost:5678/") // undef
    unless grep { $_ =~ m/no[_-]open[_-]browser$/ } @ARGV;

  # Write browser pid to a file...
  if (defined $browser_pid) {
    open my $fh, '>', catfile($App::PhotoRamp::appdata_dir, 'webgui-browser.pid')
      or warn "Cannot write browser pid to file! $!";
    print $fh "$browser_pid\n";
    close $fh;
  }

  # Monitor
  { no warnings 'once';
    $log_file = $App::PhotoRamp::WebGUI::App::server_logfile;
  }
  while (1) {
    my $t = (stat($log_file))[9];
    if (time - $t > 300) {
      warn "DEBUG: Server has been inactive as of " . time() . ", terminating.\n";
      kill 'TERM', $parent_pid;
      #kill 'TERM', $browser_pid; # leave up to show error message
      exit;
    }
    sleep 60;
  }
}

sub test_request {
  require Plack::LWPish;
  require HTTP::Request;
  require HTTP::Response;

  my $req = HTTP::Request->new(GET => 'http://localhost:5678/check-alive');
  my $res = Plack::LWPish->new->request($req); # returns HTTP::Response

  return ($res->is_success and $res->code == 200 and $res->content =~ m/OK/) ? 1 : undef;
}

my $browser_data_dir;
sub open_browser ($url) {
  $browser_data_dir = catdir($appdata_dir, 'webgui_browser_profiledata');
  remove_tree $browser_data_dir if -d $browser_data_dir;
  make_path $browser_data_dir;

  # Windows
  if (App::PhotoRamp::WINDOWS_OS()) {
    return open_browser_windows_os($url);
  } elsif (App::PhotoRamp::MAC_OS()) {
    return open_browser_mac_os($url);
  } else {
    return open_browser_nix($url);;
  }
}

sub open_browser_windows_os ($url) {
  my $rv;
  $rv = system(1, 'msedge', "--app=$url", "--user-data-dir=$browser_data_dir");
  #$rv = ...
  #  if $rv == -1;
  #
  #
  return $rv;
}

sub open_browser_mac_os ($url) {
  my @cmd = eval {
    my $app;
    return ($app, "--app=$url", "--user-data-dir=$browser_data_dir")
      if -e ($app = '/Applications/Chromium.app/Contents/MacOS/Chromium');
    return ($app, "--app=$url", "--user-data-dir=$browser_data_dir")
      if -e ($app = '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser');
    return ($app, "--app=$url", "--user-data-dir=$browser_data_dir")
      if -e ($app = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
    return ('open', $url);
  };
  my $pid = fork();
  if ($pid == 0) {
    exec(@cmd)
      or die 'Cannot exec(' . join(',' @cmd) . "): $!\n";
    exit;
  }
  return $pid;
}

sub open_browser_nix ($url) {
  my @cmd;

  # Try Flatpaks
  {
    my $flatpaks = `flatpak list --app`;
    my $flatpak_id;
    if ($flatpaks) {
      my @lines    = split /\n/, $flatpaks;
      my @browsers = ();
      foreach my $line (@lines) {
        my ($name, $id) = split /\t+/, $line;
        ($flatpak_id = $id) && last if $name =~ m/ungoogled.*chrom/i;
        ($flatpak_id = $id) && last if $name =~ m/chromium/i;
        ($flatpak_id = $id) && last if $name =~ m/brave/i;
        ($flatpak_id = $id) && last if $name =~ m/chrome/i;
      }
    }
    @cmd = ('flatpak', 'run', $flatpak_id, "--app=$url", "--user-data-dir=$browser_data_dir");
  }

  # Try snaps
  if (!@cmd) {
    my $snaps = `snap list`;
    my $snap_name;
    if ($snaps) {
      my @lines = split /\n/, $snaps;
      my @browsers = ();
      foreach my $line (@lines) {
        my ($name) = split /\s+/, $line;
        ($snap_name = $name) && last if $name =~ m/ungoogled.*chrom/i;
        ($snap_name = $name) && last if $name =~ m/chromium/i;
        ($snap_name = $name) && last if $name =~ m/brave/i;
        ($snap_name = $name) && last if $name =~ m/chrome/i;
      }
    }
    @cmd = ('snap', 'run', $snap_name, "--app=$url", "--user-data-dir=$browser_data_dir")
      if $snap_name;
  }

  # Try installed binary in user path
  if (!@cmd) {
    my $which = `which chromium`;
    chomp $which;
    @cmd = ('chromium', "--app=$url", "--user-data-dir=$browser_data_dir")
      if $which and $which =~ m/chrom/;
  }

  if (!@cmd) {
    @cmd = ('xdg-open', $url);
  }

  my $pid = fork();
  if ($pid == 0) {
    exec(@cmd)
      or die 'Cannot exec(' . join(',' @cmd) . "): $!\n";
    exit;
  }
}

__END__

Flatpak:
    1. flatpak list --app
    2. find Chrome/Chromium
    3. flatpak run APP_ID --app=URL

Snap:
    1. snap list
    2. find Chrome/Chromium
    3. snap run SNAP_NAME --app=URL

Native:
    search PATH
    google-chrome / chromium / etc.



Example Output


$ perl -E 'say `flatpak list --app`'
Transmission	com.transmissionbt.Transmission	4.1.2	stable	system
GPU-Viewer	io.github.arunsivaramanneo.GPUViewer	3.35	stable	system
Ungoogled Chromium	io.github.ungoogled_software.ungoogled_chromium	151.0.7922.137-1	stable	system
Audacity	org.audacityteam.Audacity	3.7.8	stable	system
Avidemux	org.avidemux.Avidemux	2.8.1	stable	system
FlightGear	org.flightgear.FlightGear	2024.1.6	stable	system
GNU Image Manipulation Program	org.gimp.GIMP	3.2.4	stable	system
Kate	org.kde.kate	26.04.2	stable	system
Kdenlive	org.kde.kdenlive	26.04.3	stable	system

$ perl -E 'say `snap list`'
Name               Version                         Rev    Tracking       Publisher    Notes
bare               1.0                             5      latest/stable  canonical**  base
core24             20260410                        1643   latest/stable  canonical**  base
gnome-46-2404      0+git.f1cd5fa-sdk0+git.ca9c59c  153    latest/stable  canonical**  -
gtk-common-themes  0.1-81-g442e511                 1535   latest/stable  canonical**  -
mesa-2404          25.2.8-snap288                  1839   latest/stable  canonical**  -
snapd              2.76.2                          27710  latest/stable  canonical**  snapd
supertuxkart       1.5                             678    latest/stable  lucyllewy*   -
