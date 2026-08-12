use v5.34;
use experimental 'signatures';
package App::PhotoRamp::WebGUI {

  sub start ($class) {
    my $is_parent = my $child_pid = fork();

    die "Cannot fork"
      unless defined $child_pid;

    say "PID $$ active";

    if ($is_parent) {
      require App::PhotoRamp::WebGUI::Manager;
      App::PhotoRamp::WebGUI::Manager->start;
      exit 0;
    } else {
      require App::PhotoRamp::WebGUI::Worker;
      App::PhotoRamp::WebGUI::Worker->start;
      exit 0;
    }

  }

}

1;
