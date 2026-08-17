#!perl
use v5.36;
use strict;
use warnings;
use Image::ExifTool;

my @args  = grep { $_ =~ m/^--/; } @ARGV;
my ($img) = grep { $_ !~ m/^-/ ; } @ARGV;

say "Image file: $img";

my $exiftool = Image::ExifTool->new;
my $info     = $exiftool->ImageInfo($img);
my $thumb    = $info->{ThumbnailImage};
$info->{ThumbnailImage} = 'DUMMY' if length $info->{ThumbnailImage};

use Data::Dumper;
foreach my $key (sort keys %$info) {
  say "$key:\t\t$info->{$key}";
}

my $type = $exiftool->GetValue('ThumbnailImage', 'FileType');
print "Thumbnail type: $type $$type\n";

if (grep { '--thumbnail' } @args) {
  open my $fh, '>', "thumb-$$.jpg";
  binmode $fh;
  print $fh $$thumb;
  close $fh;
}
