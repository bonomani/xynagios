#!/usr/bin/perl -w

use strict;
use Getopt::Long qw(:config bundling require_order);
use Hobbit;
use IPC::Run qw(run timeout);

sub usage ()
{
	print <<EOT;
xynagios (c) Christoph Berg <myon\@debian.org>
usage: $0 [options] check_command [command options]
  --hostname=<host> Override hostname from environment.
  --strip=<prefix>  Remove this prefix from test names; "check_" is always
                    removed.
  --test=<test>     Testname to use instead of reading from output/command.
  --help
  --version         Print this text.
Trends options: (RRD trends messages are sent if any of these is given)
  --trends          Send performance data as a "data <host>.trends" report.
  --ds=<name>       DS name (default "lambda")
  --dst=<name>      DS type (default "GAUGE")
  --heartbeat=<secs> RRD heartbeat (default 600)
  --min=<N>         DS minimum (default "U")
  --max=<N>         DS maximum (default "U")
EOT
}

my $params;

Getopt::Long::config('bundling');
if (!GetOptions (
	'--hostname=s'    =>  \$params->{'hostname'},
	'--strip=s'       =>  \$params->{'strip'},
	'--test=s'        =>  \$params->{'test'},
	'--help'          =>  \$params->{'help'},
	'--version'       =>  \$params->{'help'},
	'--trends'        =>  \$params->{'trends'},
	'--ds=s'          =>  \$params->{'ds'},
	'--dst=s'         =>  \$params->{'dst'},
	'--heartbeat=i'   =>  \$params->{'heartbeat'},
	'--min=s'         =>  \$params->{'min'},
	'--max=s'         =>  \$params->{'max'},
))
{
	usage ();
	exit (1);
};

if ($params->{help} or @ARGV == 0) {
	usage ();
	exit (0);
}

my $test;
if ($params->{'test'}) {
	$test = $params->{'test'};
} else {
	$test = $ARGV[0];
	$test =~ s!.*/!!;
	$test =~ s!\..*!!;
	$test =~ s/^check_//;
	$test =~ s/^$params->{strip}// if ($params->{strip});
}
my $bb = new Hobbit ({ test => $test, hostname => $params->{hostname} });

my ($stdin, $stdout, $stderr);
run (\@ARGV, \$stdin, \$stdout, \$stderr, timeout(300));
my $exit_code = $?;
my ($exit, $signal) = ($exit_code >> 8, $exit_code & 0xff);

if ($signal) {
	$bb->color_line ('red', "$test was killed by signal $signal, exit $exit\n");
}
if ($exit > 2) {
	$bb->color_line ('red', "$test returned exit $exit\n");
}
if ($stderr) {
	$bb->color_line ('red', "Stderr output:\n$stderr");
}
if ($exit == 2) {
	$bb->add_color ('red');
} elsif ($exit == 1) {
	$bb->add_color ('yellow');
} else {
	$bb->add_color ('green');
}

if (not $params->{'test'} and $stdout =~ s/^(\S+) +(OK|WARNING|CRITICAL|ERROR|UNKNOWN): *//s) {
	$bb->{title} = "$1 $2";
	$bb->{test} = lc ($1);
	$bb->{test} =~ s/^check_//;
	$bb->{test} =~ s/^$params->{strip}// if ($params->{strip});
}

my $trends;
if ($params->{trends} or $params->{ds} or $params->{dst} or $params->{heartbeat} or $params->{min} or $params->{max}) {
	$params->{trends} = 1;
	$params->{ds} ||= 'lambda'; # set default values
	$params->{dst} ||= 'GAUGE';
	$params->{heartbeat} ||= '600';
	$params->{min} ||= 'U';
	$params->{max} ||= 'U';
	$trends = new Hobbit ({ type => 'data', test => 'trends', hostname => $params->{hostname} });
}

# | time=0.02  postgres=4583020 template0=4349956 template1=4349956
my ($performance, $time);
if ($stdout =~ s/\s+\|\s+(.*)//) {
	my @values = split (/\s+/, $1);
	foreach my $value (@values) {
		unless ($value =~ /(.*)=(.*)/) {
			#warn "Missing = in performance value $value\n";
			next;
		}
		my ($label, @figures) = ($1, split (/;/, $2));
		$label =~ s/^'|'$//g;
		if ($label eq 'time') { # do not treat 'time' as performance data
			$time = shift (@figures);
			next;
		}
		my $value = shift (@figures);
		$performance .= "$label : $value";
		my $warn = shift @figures; $performance .= " warn $warn" if $warn;
		my $crit = shift @figures; $performance .= " crit $crit" if $crit;
		my $min = shift @figures; $performance .= " min $min" if $min;
		my $max = shift @figures; $performance .= " max $max" if $max;
		$performance .= "\n";

		if ($params->{trends}) {
			$value = $1 if ($value =~ /([-\d.]+)/);
			$trends->print ("[$bb->{test},$label.rrd]\n");
			$trends->print ("DS:$params->{ds}:$params->{dst}:$params->{heartbeat}:$params->{min}:$params->{max} $value\n");
		}
	}
}

$bb->print ($stdout);
$bb->print ("\nPerformance data:\n$performance") if $performance;
$bb->print ("\ntime $time") if $time;

$bb->send;

if ($params->{trends}) {
	$trends->send;
}

=pod

=head1 NAME

B<xynagios> - adaptor for using Nagios checks with Xymon

=head1 SYNOPSIS

B<xynagios> [I<options> --] I<plugin> [I<options ...>]

=head1 DESCRIPTION

B<xynagios> runs a Nagios check, and reports its output in a way compatible
with the Xymon (Hobbit, BB) monitoring system.

The Xymon test name is taken from the plugin output if it starts with
I<test_name> I<OK|WARNING|CRITICAL|ERROR|UNKNOWN>B<:>. Otherwise, the basename
of the plugin filename is used. A B<check_> prefix is removed for brevity.

=head1 OPTIONS

=over

=item B<--hostname=>I<host>

Report tests as this host.

=item B<--strip=>I<prefix>

Remove I<prefix> (regexp) from test names. The prefix "check_" is always
removed before stripping other prefixes. Useful for trimming down overly
verbose Nagios test names, e.g. "check_postgres_database_size" to
"database_size".

=item B<--test=>I<name>

Test name to submit. Per default, the test name is derived from the plugin
output, or from the plugin name, if the output doesn't indicate the name.

=item B<--help>

=item B<--version>

Print help text and version, and exit.

=back

Options for sending RRD trends messages. If any of these is set, a data
I<host>.trends message is sent.

=over 4

=item B<--trends>

In addition to printing performance data in the status report (suitable for the
NCV/SPLITNCV xymond_rrd modules), send in a data report for
I<hostname>B<.trends>. This rrd module is more robust.

=item B<--ds=>I<name>

The data source (DS) I<name> used in the RRD files, defaults to B<lambda>.

=item B<--dst=>I<type>

The data source I<type> used in the RRD files. Useful values are B<GAUGE> (the
default), B<COUNTER>, B<DCOUNTER>, B<DERIVE>, B<DDERIVE>, and B<ABSOLUTE>. See
rrdcreate(1) for details.

=item B<--heartbeat=>I<secs>

RRD heartbeat in seconds, default is 600.

=item B<--min=>I<N>

Data source minimum value, default is B<U> for unknown.

=item B<--max=>I<N>

Data source maximum value, default is B<U> for unknown.

=back

=head1 SEE ALSO

xymon(7), xymon(1), xymoncmd(1), nagios3(8).

=head1 AUTHOR

Christoph Berg <myon@debian.org>

=head1 LICENSE AND COPYRIGHT

Copyright (c) Christoph Berg <myon@debian.org>

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  1. Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright notice,
     this list of conditions and the following disclaimer in the documentation
     and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
OF SUCH DAMAGE.

=cut
