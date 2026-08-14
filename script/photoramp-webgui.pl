#!perl
use HTTP::Server::PSGI;
use App::PhotoRamp;
use App::PhotoRamp::WebGUI::App;

my $server = HTTP::Server::PSGI->new(
  host => '127.0.0.1',
  port => 5678,
  timeout => 60,
);

my $app = App::PhotoRamp::WebGUI::App->app_with_static_server;
$server->run($app);
