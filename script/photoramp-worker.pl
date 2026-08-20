#!perl
use warnings;
use v5.26;
use JSON::MaybeXS;

$0 = "PhotoRamp Task Worker ($$)";
say "Task worker $$ launched.";

my $env_file = pop @ARGV;
open my $fh, '<', $env_file
  or die "Cannot open $env_file: $!";
my $data = join '', <$fh>;
close $fh;

$data    = decode_json($data);
my $PENV = $data->{PENV};

$ENV{"PHOTORAMP_$_"} = $PENV->{$_} for keys %$PENV;

eval 'require App::PhotoRamp; 1'
  or die "Cannot require App::photoRamp: $@";

App::PhotoRamp::do_tasks($data->{tasks}->@*);
say "Task worker $$ finished.";
