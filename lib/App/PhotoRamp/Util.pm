use v5.26;
use strict;
use warnings;
package App::PhotoRamp::Util {
  use App::PhotoRamp::Signatures;
  use constant KiB => 1024;
  use constant MiB => 1024*KiB;

  # Set up exporter
  use parent 'Exporter';
  our @EXPORT_OK = qw(
    encode_u64
    decode_u64
    b64_to_u64
    u64_to_b64
    gzip_file
  );
  our %EXPORT_TAGS = ( all => \@EXPORT_OK );

  #
  # Base 64 functions
  #
  sub encode_u64 ($str) { b64_to_u64(MIME::Base64::encode($str)) }
  sub decode_u64 ($str) { MIME::Base64::decode(u64_to_b64($str)) }
  sub b64_to_u64 ($str) { $str =~ tr`+/=\n`-_`dr }
  sub u64_to_b64 ($str) { $str =~ tr`-_`+/`r     }

  #
  # Gzip function
  #
  sub gzip_file ($from, $to, :$buffer_size = 4*MiB, :$level = 6) {
    require Gzip::Libdeflate;
    my $gzip    = Gzip::Libdeflate->new(level => $level);
    open my $rfh, '<', $from
      or die "Cannot open $from: $!";
    open my $wfh, '>', $to
      or die "Cannot open $to: $!";
    my $buf = '';
    binmode $rfh;
    binmode $wfh;
    while (read($rfh, $buf, $buffer_size)) {
      my $out = $gzip->compress($buf);
      print $wfh $out;
    }
    close $rfh;
    close $wfh;
  }
}

1;
