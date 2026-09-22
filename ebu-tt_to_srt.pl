#!/usr/bin/env perl

###############################################################################
# ebu-tt_to_srt.pl
#
# EBU-TT / TTML -> SRT converter
#
# Version 2.0
#
# Features:
#   - XML::LibXML based parser
#   - proper namespace handling
#   - UTF-8 input/output
#   - automatic output filename
#   - explicit input/output arguments
#   - automatic documentStartOfProgramme detection
#   - explicit --offset override
#   - clock-time timestamps
#   - media/offset timestamps
#   - frame-based timestamps
#   - configurable frame rate
#   - frameRate / frameRateMultiplier / subFrameRate detection
#   - <br/> -> SRT line break
#   - nested <span> handling
#   - XML whitespace handling
#   - empty subtitle detection
#   - invalid timestamp detection
#   - negative timestamps clamped to zero
#   - malformed subtitle handling
#   - optional strict mode
#   - optional verbose diagnostics
#
# Dependencies:
#   XML::LibXML
#
# Example:
#   ./ebu-tt_to_srt.pl input.xml
#
#   ./ebu-tt_to_srt.pl input.xml output.srt
#
#   ./ebu-tt_to_srt.pl --offset 10:00:00 input.xml output.srt
#
###############################################################################

use strict;
use warnings;
use utf8;

use Getopt::Long qw(GetOptions);
use File::Basename qw(fileparse);
use XML::LibXML;

use constant {
    VERSION => '2.0.0',
};

###############################################################################
# Configuration
###############################################################################

my %opt = (
    output       => undef,
    offset       => undef,
    fps          => undef,
    encoding     => 'UTF-8',
    strict       => 0,
    verbose      => 0,
    keep_empty   => 0,
    no_auto_offset => 0,
);

###############################################################################
# Command line
###############################################################################

sub usage {
    return <<"EOF";

ebu-tt_to_srt.pl v${\VERSION}

Convert EBU-TT / TTML subtitles to SRT.

Usage:

    ebu-tt_to_srt.pl [options] input.xml [output.srt]

Options:

    -o, --output FILE
        Output SRT filename.

    --offset TIME
        Explicit timestamp offset.

        Example:
            --offset 10:00:00
            --offset 10:00:00.000

    --fps RATE
        Explicit frame rate for frame-based timestamps.

        Examples:
            --fps 25
            --fps 25/1
            --fps 30000/1001

        If omitted, the value is taken from ttp:frameRate
        and ttp:frameRateMultiplier when available.

    --no-auto-offset
        Do not use ebuttm:documentStartOfProgramme automatically.

    --keep-empty
        Keep subtitles whose text content is empty.

    --strict
        Stop on malformed subtitle data instead of skipping it.

    -v, --verbose
        Print diagnostic information.

    -h, --help
        Show this help.

    --version
        Show program version.

Examples:

    ebu-tt_to_srt.pl subtitles.xml

    ebu-tt_to_srt.pl subtitles.xml subtitles.srt

    ebu-tt_to_srt.pl \\
        --offset 10:00:00 \\
        subtitles.xml subtitles.srt

    ebu-tt_to_srt.pl \\
        --fps 25 \\
        subtitles.xml subtitles.srt

EOF
}

GetOptions(
    'output|o=s'       => \$opt{output},
    'offset=s'         => \$opt{offset},
    'fps=s'            => \$opt{fps},
    'strict'           => \$opt{strict},
    'verbose|v'        => \$opt{verbose},
    'keep-empty'       => \$opt{keep_empty},
    'no-auto-offset'   => \$opt{no_auto_offset},
    'help|h'           => sub {
        print usage();
        exit 0;
    },
    'version'          => sub {
        print VERSION, "\n";
        exit 0;
    },
) or die usage();

my @args = @ARGV;

die usage() unless @args;

my $input = shift @args;

die "Unexpected argument(s): @args\n"
    if @args > 1;

if (!-f $input) {
    die "Input file does not exist: $input\n";
}

###############################################################################
# Output filename
###############################################################################

if (defined $opt{output}) {
    $opt{output} = $opt{output};
}
elsif (@args) {
    $opt{output} = $args[0];
}
else {
    my ($name) = fileparse($input, qr/\.[^.]*/);
    $opt{output} = $name . '.srt';
}

###############################################################################
# XML parser
###############################################################################

my $parser = XML::LibXML->new(
    recover      => 0,
    no_network   => 1,
    load_ext_dtd => 0,
    expand_entities => 0,
);

my $doc;

eval {
    $doc = $parser->parse_file($input);
};

if ($@ || !$doc) {
    my $error = $@ || 'unknown XML parsing error';
    chomp $error;

    die "Unable to parse XML file '$input': $error\n";
}

###############################################################################
# Namespace handling
###############################################################################

my $xpc = XML::LibXML::XPathContext->new($doc);

# TTML namespace
$xpc->registerNs(
    'tt',
    'http://www.w3.org/ns/ttml'
);

# TTML parameter namespace
$xpc->registerNs(
    'ttp',
    'http://www.w3.org/ns/ttml#parameter'
);

# EBU-TT metadata namespace
$xpc->registerNs(
    'ebuttm',
    'urn:ebu:tt:metadata'
);

###############################################################################
# Document parameters
###############################################################################

my $root = $doc->documentElement;

my $time_base = $root->getAttribute('timeBase');

$time_base = 'media'
    unless defined($time_base) && length($time_base);

my $frame_rate = detect_frame_rate(
    root => $root,
    xpc  => $xpc,
);

if (defined $opt{fps}) {
    $frame_rate = parse_frame_rate($opt{fps});
}

if ($opt{verbose}) {
    print STDERR "Input:       $input\n";
    print STDERR "Output:      $opt{output}\n";
    print STDERR "timeBase:    $time_base\n";
    print STDERR "frame rate:  $frame_rate\n";
}

###############################################################################
# Determine timestamp offset
###############################################################################

my $offset = 0;

if (defined $opt{offset}) {

    $offset = parse_timestamp(
        $opt{offset},
        frame_rate => $frame_rate,
        time_base  => $time_base,
    );

    verbose(
        "Using explicit offset: " .
        format_seconds($offset)
    );
}
elsif (!$opt{no_auto_offset}) {

    my $document_start =
        find_document_start_of_programme($xpc);

    if (defined $document_start) {

        eval {
            $offset = parse_timestamp(
                $document_start,
                frame_rate => $frame_rate,
                time_base  => $time_base,
            );
        };

        if ($@) {
            my $error = $@;
            chomp $error;

            warn
                "Warning: unable to parse " .
                "documentStartOfProgramme '$document_start': " .
                "$error\n";

            $offset = 0;
        }
        else {
            verbose(
                "Using documentStartOfProgramme: " .
                "$document_start (" .
                format_seconds($offset) .
                ")"
            );
        }
    }
}

###############################################################################
# Find subtitles
###############################################################################

my @paragraphs = $xpc->findnodes(
    '/tt:tt/tt:body//tt:p'
);

if (!@paragraphs) {
    die "No TTML subtitle paragraphs (<tt:p>) found.\n";
}

verbose("Found " . scalar(@paragraphs) . " subtitle(s)");

###############################################################################
# Open output
###############################################################################

open(
    my $out,
    '>:encoding(UTF-8)',
    $opt{output}
)
or die "Unable to open '$opt{output}' for writing: $!\n";

###############################################################################
# Convert subtitles
###############################################################################

my $srt_number = 1;
my $written    = 0;
my $skipped    = 0;

for my $p (@paragraphs) {

    my $begin = $p->getAttribute('begin');
    my $end   = $p->getAttribute('end');
    my $dur   = $p->getAttribute('dur');

    #
    # Some TTML documents may use begin + dur instead of begin + end.
    #
    if (
        defined($begin) &&
        length($begin) &&
        (!defined($end) || !length($end)) &&
        defined($dur) &&
        length($dur)
    ) {
        eval {

            my $begin_seconds = parse_timestamp(
                $begin,
                frame_rate => $frame_rate,
                time_base  => $time_base,
            );

            my $duration_seconds = parse_timestamp(
                $dur,
                frame_rate => $frame_rate,
                time_base  => $time_base,
                duration   => 1,
            );

            $end =
                format_seconds(
                    $begin_seconds + $duration_seconds
                );
        };

        if ($@) {
            handle_error(
                "Unable to calculate end time for subtitle",
                $p,
            );

            $skipped++;
            next;
        }
    }

    unless (
        defined($begin) && length($begin) &&
        defined($end)   && length($end)
    ) {
        handle_error(
            "Subtitle has no valid begin/end timing",
            $p,
        );

        $skipped++;
        next;
    }

    my ($begin_seconds, $end_seconds);

    eval {

        $begin_seconds = parse_timestamp(
            $begin,
            frame_rate => $frame_rate,
            time_base  => $time_base,
        );

        $end_seconds = parse_timestamp(
            $end,
            frame_rate => $frame_rate,
            time_base  => $time_base,
        );
    };

    if ($@) {
        handle_error(
            "Invalid subtitle timestamp: " . $@,
            $p,
        );

        $skipped++;
        next;
    }

    #
    # Apply programme offset.
    #
    $begin_seconds -= $offset;
    $end_seconds   -= $offset;

    #
    # SRT does not support negative timestamps.
    #
    $begin_seconds = 0
        if $begin_seconds < 0;

    $end_seconds = 0
        if $end_seconds < 0;

    #
    # Prevent malformed SRT intervals.
    #
    if ($end_seconds < $begin_seconds) {

        handle_error(
            sprintf(
                "Subtitle ends before it begins: %.3f > %.3f",
                $begin_seconds,
                $end_seconds,
            ),
            $p,
        );

        $skipped++;
        next;
    }

    #
    # Extract textual content.
    #
    my $text = extract_text($p);

    unless (length($text)) {

        unless ($opt{keep_empty}) {
            verbose(
                "Skipping empty subtitle"
            );

            $skipped++;
            next;
        }
    }

    #
    # Write SRT.
    #
    print {$out} $srt_number, "\n";

    print {$out}
        format_srt_time($begin_seconds),
        " --> ",
        format_srt_time($end_seconds),
        "\n";

    print {$out} $text, "\n\n";

    $srt_number++;
    $written++;
}

close($out)
or die "Unable to close '$opt{output}': $!\n";

###############################################################################
# Summary
###############################################################################

print
    "Written SRT: $opt{output}\n",
    "Subtitles:   $written\n";

print
    "Skipped:     $skipped\n"
    if $skipped;

exit 0;

###############################################################################
# Functions
###############################################################################

sub verbose {
    return unless $opt{verbose};

    print STDERR "[ebu-tt_to_srt] ", @_, "\n";
}

###############################################################################

sub handle_error {
    my ($message, $node) = @_;

    if ($opt{strict}) {
        die "$message\n";
    }

    warn "Warning: $message\n";
}

###############################################################################

sub detect_frame_rate {
    my (%args) = @_;

    my $root = $args{root};

    my $frame_rate =
        $root->getAttribute('frameRate');

    my $multiplier =
        $root->getAttribute('frameRateMultiplier');

    #
    # EBU-TT / TTML uses:
    #
    # frameRate
    # frameRateMultiplier
    #
    # Example:
    #
    # frameRate="30000"
    # frameRateMultiplier="1001 1000"
    #
    if (
        defined($frame_rate) &&
        length($frame_rate)
    ) {

        my $fps =
            parse_frame_rate($frame_rate);

        if (
            defined($multiplier) &&
            length($multiplier)
        ) {

            if (
                $multiplier =~
                /^\s*(\d+)\s+(\d+)\s*$/
            ) {

                my ($num, $den) =
                    ($1, $2);

                die
                    "Invalid frameRateMultiplier"
                    if $den == 0;

                $fps *= $num / $den;
            }
        }

        return $fps;
    }

    #
    # Common broadcast default.
    #
    return 25;
}

###############################################################################

sub parse_frame_rate {
    my ($value) = @_;

    if ($value =~ /^\s*(\d+(?:\.\d+)?)\s*$/) {
        my $fps = $1 + 0;

        die "Frame rate must be > 0\n"
            if $fps <= 0;

        return $fps;
    }

    if ($value =~ /^\s*(\d+)\s*\/\s*(\d+)\s*$/) {

        my ($num, $den) =
            ($1, $2);

        die "Frame rate denominator must not be zero\n"
            if $den == 0;

        return $num / $den;
    }

    die "Invalid frame rate: $value\n";
}

###############################################################################

sub find_document_start_of_programme {
    my ($xpc) = @_;

    #
    # EBU-TT metadata commonly appears as:
    #
    # <ebuttm:documentStartOfProgramme>
    #     10:00:00:00
    # </ebuttm:documentStartOfProgramme>
    #
    # We also tolerate an attribute representation.
    #

    my @nodes = $xpc->findnodes(
        '//*[local-name()="documentStartOfProgramme"]'
    );

    for my $node (@nodes) {

        #
        # Attribute form
        #
        my $value =
            $node->getAttribute('value');

        return $value
            if defined($value) && length($value);

        #
        # Text form
        #
        $value = $node->textContent;

        if (defined($value)) {

            $value =~ s/^\s+//;
            $value =~ s/\s+$//;

            return $value
                if length($value);
        }
    }

    #
    # Some documents use the metadata attribute directly.
    #
    my @attributes =
        $xpc->findnodes(
            '//@ebuttm:documentStartOfProgramme'
        );

    for my $attribute (@attributes) {

        my $value = $attribute->value;

        return $value
            if defined($value) && length($value);
    }

    return undef;
}

###############################################################################

sub parse_timestamp {
    my ($value, %args) = @_;

    my $fps =
        $args{frame_rate} || 25;

    my $time_base =
        $args{time_base} || 'media';

    die "Undefined timestamp\n"
        unless defined($value);

    $value =~ s/^\s+//;
    $value =~ s/\s+$//;

    #
    # Clock time:
    #
    # HH:MM:SS
    # HH:MM:SS.mmm
    # HH:MM:SS:FF
    #
    if (
        $value =~
        /^(\d+):(\d{2}):(\d{2})(?:\.(\d+))?$/
    ) {

        my ($hours, $minutes, $seconds, $fraction) =
            ($1, $2, $3, $4);

        die "Invalid minutes in timestamp '$value'\n"
            if $minutes > 59;

        die "Invalid seconds in timestamp '$value'\n"
            if $seconds > 59;

        my $fraction_seconds = 0;

        if (defined $fraction) {
            $fraction_seconds =
                ("0.$fraction") + 0;
        }

        return
            $hours * 3600 +
            $minutes * 60 +
            $seconds +
            $fraction_seconds;
    }

    #
    # Clock time with frames:
    #
    # HH:MM:SS:FF
    #
    if (
        $value =~
        /^(\d+):(\d{2}):(\d{2}):(\d+)$/
    ) {

        my ($hours, $minutes, $seconds, $frames) =
            ($1, $2, $3, $4);

        die "Invalid minutes in timestamp '$value'\n"
            if $minutes > 59;

        die "Invalid seconds in timestamp '$value'\n"
            if $seconds > 59;

        die "Invalid frame number '$frames'\n"
            if $frames >= $fps;

        return
            $hours * 3600 +
            $minutes * 60 +
            $seconds +
            ($frames / $fps);
    }

    #
    # Offset time expressions:
    #
    # 10h
    # 500ms
    # 10s
    # 25m
    # 100f
    #
    if ($value =~ /^(\d+(?:\.\d+)?)(h|m|s|ms|f)$/) {

        my ($number, $unit) =
            ($1, $2);

        return $number * 3600
            if $unit eq 'h';

        return $number * 60
            if $unit eq 'm';

        return $number
            if $unit eq 's';

        return $number / 1000
            if $unit eq 'ms';

        return $number / $fps
            if $unit eq 'f';
    }

    die
        "Unsupported timestamp expression '$value'\n";
}

###############################################################################

sub format_seconds {
    my ($seconds) = @_;

    return sprintf(
        "%.3f",
        $seconds,
    );
}

###############################################################################

sub format_srt_time {
    my ($seconds) = @_;

    $seconds = 0
        if $seconds < 0;

    #
    # SRT uses millisecond precision.
    #
    my $milliseconds =
        int($seconds * 1000 + 0.5);

    my $hours =
        int($milliseconds / 3_600_000);

    $milliseconds %= 3_600_000;

    my $minutes =
        int($milliseconds / 60_000);

    $milliseconds %= 60_000;

    my $secs =
        int($milliseconds / 1000);

    $milliseconds %= 1000;

    return sprintf(
        '%02d:%02d:%02d,%03d',
        $hours,
        $minutes,
        $secs,
        $milliseconds,
    );
}

###############################################################################

sub extract_text {
    my ($paragraph) = @_;

    my $text = '';

    #
    # Walk all direct/descendant children in document order.
    #
    # This is important because TTML allows:
    #
    # <p>
    #   Hello
    #   <span>world</span>
    #   <br/>
    #   <span>again</span>
    # </p>
    #
    for my $node ($paragraph->childNodes()) {

        $text .= extract_node_text($node);
    }

    #
    # Normalize CR/LF.
    #
    $text =~ s/\r\n/\n/g;
    $text =~ s/\r/\n/g;

    #
    # Remove trailing spaces from lines.
    #
    $text =~ s/[ \t]+\n/\n/g;

    #
    # Remove spaces introduced immediately after line breaks.
    #
    $text =~ s/\n[ \t]+/\n/g;

    #
    # Collapse excessive blank lines.
    #
    $text =~ s/\n{3,}/\n\n/g;

    #
    # Remove whitespace surrounding the complete subtitle.
    #
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;

    return $text;
}

###############################################################################

sub extract_node_text {
    my ($node) = @_;

    #
    # Text node
    #
    if ($node->nodeType == XML_TEXT_NODE) {

        return $node->data;
    }

    #
    # Explicit TTML line break
    #
    if (
        $node->nodeType == XML_ELEMENT_NODE &&
        $node->localname eq 'br'
    ) {
        return "\n";
    }

    #
    # Other elements: recursively process children.
    #
    my $text = '';

    for my $child ($node->childNodes()) {
        $text .= extract_node_text($child);
    }

    return $text;
}

###############################################################################
