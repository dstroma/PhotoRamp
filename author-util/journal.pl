#!perl
use v5.44;
use App::PhotoRamp::Journal;

my $dbfile = "./test-$$.sqlt";
warn "dbfile: $dbfile";

my $jrn = App::PhotoRamp::Journal->new_or_open($dbfile);

$jrn->log_action("/Users/dstroma/Pictures/IMG_0128.JPG" => "/Users/dstroma/Pictures/IMG_0128 copy.JPG", action => 'COPY', reason => 'TEST');
