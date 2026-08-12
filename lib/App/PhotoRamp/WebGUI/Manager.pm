use v5.34;
use experimental 'signatures';
use experimental 'try';
package App::PhotoRamp::WebGUI::Manager {
  use parent 'HTTP::Server::Simple::CGI';
  use DateTime;
  our $port = 5555;

  sub handle_request ($self, $cgi) {
    print "HTTP/1.0 200 OK\r\n";
    print $cgi->header,
          $cgi->start_html('Test page'),
          $cgi->h1('You are on a test page'),
          $cgi->p('It is ' . DateTime->now()->stringify),
          $cgi->end_html;
    print "\r\n\r\n";
  }

  sub start ($class) {
    my $try_again = 1;
    while ($try_again and $port < 9999) {
      try {
        say "Attempting to launch PhotoRamp WebGUI on port $port (PID $$)";
        my $server = $class->new($port)->run;
        $try_again = 0;
      } catch ($e) {
        $try_again = 1;
        $port++;
      }
    }
  }

}

1;
