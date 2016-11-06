#!/usr/bin/perl

# http://bbc.github.io/subtitle-guidelines/

use strict;
use warnings;
use utf8;
use XML::Simple;
use Data::Dumper;
use POSIX qw{strftime};

# force writing utf8 compatible output
binmode(STDOUT, ":utf8");

my $input = XMLin('ebu-tt.xml');

my $lineCount = 1;

foreach my $data (@{$input->{"tt:body"}->{"tt:div"}->{"tt:p"}}) {
        # uncomment for debugging purpose..
        # print Dumper($data);

        print $lineCount . "\n";

        (my $begin = $data->{begin}) =~ s/\./\,/;
        (my $end = $data->{end})     =~ s/\./\,/;

        # ebuttm:documentStartOfProgramme
        # 10:00:00:00 or 20:00:00:00
        $begin =~ s/^1|^2/0/;
        $end   =~ s/^1|^2/0/;

        print $begin . " --> " . $end . "\n";

        # check if content has more than one line, which is stored as array
        if (ref $data->{"tt:span"} eq 'ARRAY') {
            foreach my $contentLine (@{$data->{"tt:span"}}) {
                print ${$contentLine}{content} . "\n";
            }
        } else {
            print $data->{"tt:span"}->{content} . "\n" if ($data->{"tt:span"}->{content});
        }

        print "\n";
        $lineCount++;
}
