package IDKit::Harness;
use strict;
use warnings;
use parent 'TAP::Harness';

# Keep all TAP parsing, assertion accounting, and exit-status handling in the
# standard harness. Our only policy: selected tests must actually run.
sub summary {
    my ($self, $aggregate) = @_;
    for my $parser ($aggregate->parsers) {
        die "ID kit: unexpected SKIP, TODO, or empty test file\n"
            if $parser->skip_all || $parser->skipped || $parser->todo || !$parser->tests_run;
    }
    return $self->SUPER::summary($aggregate);
}
1;
