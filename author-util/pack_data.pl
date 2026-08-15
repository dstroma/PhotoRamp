#!perl
use v5.36;
use File::Find qw(find);
use Gzip::Libdeflate;
use MIME::Base64 qw(encode_base64);
use File::Copy qw(copy);
use autodie;

my $gz = Gzip::Libdeflate->new(level => 6);

my @dirs = ('./static', './template');
my @files;

find(sub {
  push @files, $File::Find::name if -f and $_ !~ m/^\./
}, @dirs);

copy('./lib/App/PhotoRamp/WebGUI/Data.pm.src', './lib/App/PhotoRamp/WebGUI/Data.pm');

open my $outfh, '>>', './lib/App/PhotoRamp/WebGUI/Data.pm';
print $outfh "\r\n__END__\r\n";

foreach my $filename (sort { $a cmp $b } @files) {
  # Gzip and get base56
  open my $infh, '<', $filename;
  my $filecont = encode_base64($gz->compress(join '', <$infh>));
  close $infh;

  print $outfh "$filename\r\n";
  print $outfh length($filecont) . "\r\n";
  print $outfh $filecont;
  print $outfh "\r\n";
}

close $outfh;
