#!perl
use v5.36;
use strict;
use warnings;
use Image::ExifTool;

my $exiftool = Image::ExifTool->new;
my $info     = $exiftool->ImageInfo($ARGV[0]);
$info->{ThumbnailImage} = 'DUMMY' if length $info->{ThumbnailImage};

use Data::Dumper;
foreach my $key (sort keys %$info) {
  say "$key:\t\t$info->{$key}";
}

