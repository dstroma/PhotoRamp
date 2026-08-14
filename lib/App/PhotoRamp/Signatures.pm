use strict;
use warnings;
package App::PhotoRamp::Signatures {
  sub import {
    if ($] >= 5.044) {
      eval q{
        use v5.44;
        use feature 'signatures';
        feature->import('signatures');
        1
      } or die $@;
    } elsif ($] >= 5.038) {
      eval q{
        use v5.38;
        use feature 'signatures';
        feature->import('signatures');
        require Sublike::Extended;
        Sublike::Extended->import('sub', 'method');
        1
      } or die $@;
    } elsif ($] >= 5.026) {
      eval q{
        use v5.26;
        use feature 'signatures';
        feature->import('signatures');
        require Sublike::Extended;
        Sublike::Extended->import('sub');
        1
      } or die $@;
    } else {
      die "Unsupported perl version < 5.26.0!";
    }

    eval q{warnings->unimport('experimental::signatures')};
    eval q{warnings->unimport('experimental::signature_named_parameters')};
  }
}

1;
