#!/usr/bin/perl -w
use strict;
use lib "./dist/Module-CoreList/lib";

# Copyright 2011 Niko Tyni
# 
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

# This script was created for checking the Breaks/Replaces/Provides
# triplets in the debian/control file of the Debian perl source package.
#
# 1) check the versioned Breaks against Module::CoreList information
#  
# 2) check that all Breaks entries have appropriate Replaces and Provides
#    entries
#
# 3) check that there are no packages in the Debian archive (as seen via
#    the local apt package cache) that should have Breaks/Replaces/Provides
#    entries
#
# See the the hashes below for hardcoded special cases that will probably
# need to be updated in the future.

# get the list of deprecated packages
my %deprecated;
require './lib/deprecate.pm';
{ 
	no warnings 'once';
	%deprecated = reverse %deprecate::DEBIAN_PACKAGES;
}

# list packages that have acquired more digits in Debian than upstream uses
# this happens because CPAN and Debian versioning systems differ
my %known_digits = (
    "libfile-spec-perl"  => 4,
    "libtime-local-perl" => 4,
    "libtime-piece-perl" => 4,
    "libjson-pp-perl"    => 5,
    "libextutils-parsexs-perl" => 6,
);

# list special cases of version numbers that are OK here
# version numbering discontinuities and backported fixes cause these
my %ok = (
       "libencode-perl" => {
               # bug #836138
               "2.72" => "2.86",
               "2.80_01" => "2.86",
               # bug #880085
               "2.88" => "2.94",
       },
       "libtest-simple-perl" => {
               "0.98" => "0.98",
       },
       "libmodule-corelist-perl" => {
               "3.10" => "3.10",
       },
       # bug #808629
       "libautodie-perl" => {
                "2.26"   => "2.29",
       },
);

# epochs in the archive (including past ones)
my %known_epochs = (
	"libversion-perl" => "1",
	"libscalar-list-utils-perl" => "1",
	"libnet-perl" => "1",
);

# list special cases where a Breaks entry doesn't need to imply
# Replaces+Provides
my %triplet_check_skip = (
	"perl-base" => [ "libfile-spec-perl" ],
	"libperl5.36" => [ "libfilter-perl" ],
);

# list special cases where the name of the Debian package does not
# match a module name that has a right $VERSION entry
my %special_modules = (
	"libcgi-pm-perl" => 'CGI',
	"libansicolor-perl" => 'Term::ANSIColor',
	"libio-compress-perl" => "IO::Compress::Gzip",
	"libio-compress-zlib-perl" => "IO::Compress::Gzip",
	"liblocale-codes-perl" => "Locale::Country",
	"libscalar-list-utils-perl" => "List::Util",
	"podlators-perl" => "Pod::Man",
	"libnet-perl" => "Net::Cmd",
	"libfilter-perl" => "Filter::Util::Call",
);

# list special cases where we're not providing a dual-lived module from
# core even though Module::CoreList says we are. Arguably we should
# patch our Module::CoreList, but that module probably works better as a
# reference point than something which matches the Debian view of the world.
my %not_in_debian_core = (
    "libcgi-fast-perl" => 1,
);

use Test::More;
use Module::CoreList;
use Dpkg::Control::Info;
use Dpkg::Deps;

use AptPkg::Config '$_config';
use AptPkg::System '$_system';
use AptPkg::Cache;
_init_AptPkg();

# AptPkg offers a proper Debian version comparison mechanism
my $versioning = $_system->versioning;
my $apt = AptPkg::Cache->new;

# slurp in the control info
my $control = Dpkg::Control::Info->new(shift || "debian/control");

my $perl_version = get_perl_version();

# the 5.10 packaging used Conflicts; 5.12 onwards uses Breaks
my $breaksname = ($perl_version <= 5.010001 ? "Conflicts" : "Breaks");

# initialize the corelist info
my $corelist = $Module::CoreList::version{$perl_version};
die(qq(no Module::CoreList information found for $perl_version (try "perl -Idist/Module-CoreList/lib $0")))
	if !defined $corelist;

# for the known modules in the corelist, create a mapping
# from a probable Debian package name to the CPAN distribution name
#
# this is mostly to get the casing right (Io vs. IO etc.)
my %debian_from_cpan_guess;
for my $cpan_name (keys %$corelist) {
	my $guess = "lib" . (lc $cpan_name) . "-perl";
	$guess =~ s/::/-/g;
	$debian_from_cpan_guess{$guess} = $cpan_name;
}

# we also store the other way around so we don't have to do
# the above dance every time
my %cpan_from_debian_guess = reverse %debian_from_cpan_guess;

# cache the list of our own binary packages for later
my %is_perl_binary;

my %deps_found;
my $breaks_total = 0;
my $tests_per_breaks = 6;

for my $perl_package_info ($control->get_packages) {
	my $perl_package_name = $perl_package_info->{Package};
	my $dep_found = $deps_found{$perl_package_name} ||= {};
	$is_perl_binary{$perl_package_name}++;
	next if !exists $perl_package_info->{$breaksname};

	# cache all the targets for Breaks, Replaces and Provides for later
	# we store Dpkg::Deps::Simple objects for each target
	for my $deptype ($breaksname, "Replaces", "Provides") {
		next if !exists $perl_package_info->{$deptype};

		# Dpkg::Deps cannot parse unsubstituted substvars so remove this
		$perl_package_info->{$deptype} =~ s/\$\{perlapi:Provides}//;

		my $parsed = deps_parse($perl_package_info->{$deptype});
		next if !defined $parsed;
		for my $target ($parsed->get_deps) {
			$dep_found->{$deptype}{$target->{package}} = $target;
			$breaks_total++ if $deptype eq $breaksname;
		}
	}
}

plan tests => $tests_per_breaks * $breaks_total + 2;

ok($breaks_total, "successfully parsed debian/control");

for my $perl_package_name (keys %deps_found) {
	my $dep_found = $deps_found{$perl_package_name};
	my $providing_package = ($perl_package_name eq 'perl-base' ? 'perl-base' : 'perl');
	my $providing_dep = $deps_found{$providing_package};
	# go through all the Breaks targets
	#  check the version against Module::CoreList
	#  check for appropriate Replaces and Provides entries 
	#
	for my $broken (keys %{$dep_found->{$breaksname}}) {
		my $module = deb2cpan($broken);
		my ($epoch, $digits) = (0, 0);

		$epoch = $known_epochs{$broken}
			if exists $known_epochs{$broken};

		$digits = $known_digits{$broken}
			if exists $known_digits{$broken};

		SKIP: {
			my $broken_version = $dep_found->{$breaksname}{$broken}{version};

			skip("$module Breaks entry is unversioned", $tests_per_breaks)
				if !defined $broken_version;

			$broken_version =~ s/-\d+$//; # remove the Debian revision

			skip("$module is unknown to Module::CoreList", $tests_per_breaks)
				if !exists $corelist->{$module};

			my $corelist_version =
				cpan_version_to_deb($corelist->{$module}, $broken, $digits);
			$corelist_version = $epoch . ":". $corelist_version
				if $epoch;

			is($broken_version, $corelist_version,
				"Breaks for $broken in $perl_package_name matches Module::CoreList for $module");
			# help automating fixes for major version upgrades
			# usage example:
			#  prove -v debian/t/control.t 2>&1 | sed -n 's,# s/,s/, p' | sed -f - -i debian/control
			if ($broken_version ne $corelist_version) {
				diag("s/$broken (<< $broken_version)/$broken (<< $corelist_version)/");
			}

			# check if separate packages in the archive have introduced epochs
			# or extra digits that we don't know of
			#
			# if they have, it's still fine if our version of the module with
			# those digits and epoch is earlier than the one in the archive
			#
			# otherwise we have a newer version than the separate package in the
			# archive and need to update our versions in Breaks etc.

			my ($current_epoch_in_breaks, $current_digits_in_breaks) =
			   parse_epoch_and_digits_from_version($broken, $broken_version);

			my $current_version_in_archive = get_archive_upstream_version($broken);
			my ($current_epoch_in_archive, $current_digits_in_archive) =
			   parse_epoch_and_digits_from_version($broken, $current_version_in_archive);

			if ($current_epoch_in_archive  eq $current_epoch_in_breaks and
			   ($current_digits_in_archive eq $current_digits_in_breaks or
			    $current_digits_in_archive == 0)) { # probably just a virtual package

				ok (1, "no digit or epoch changes found in the archive for $broken");
			} else {
				my $mangled_corelist_version =
					cpan_version_to_deb($corelist->{$module}, $broken, $current_digits_in_archive);
				$mangled_corelist_version = $current_epoch_in_archive. ":". $mangled_corelist_version
					if $current_epoch_in_archive > 0;
				ok ($versioning->compare($mangled_corelist_version, $current_version_in_archive) < 0,
					"new digits or epoch in the archive found for $broken ($broken_version vs $current_version_in_archive) but no updates needed yet")
			}

			skip("not checking Replaces and Provides for $broken in $perl_package_name", $tests_per_breaks - 2)
				if $triplet_check_skip{$perl_package_name} &&
					grep { $_ eq $broken } @{$triplet_check_skip{$perl_package_name}};

			if (exists $deprecated{$broken}) {
				ok(!exists $providing_dep->{Provides}{$broken},
					"Breaks for deprecated package $broken in $perl_package_name does not imply Provides");
				ok(!exists $dep_found->{Replaces}{$broken},
					"Breaks for deprecated package $broken in $perl_package_name does not imply Replaces");
				SKIP: {
					skip("no need to check Replaces or Provides versions for deprecated package $broken in $perl_package_name", 2);
				}
			} else {
				ok(exists $providing_dep->{Provides}{$broken},
					"Breaks for $broken in $perl_package_name implies Provides");
				ok(exists $dep_found->{Replaces}{$broken},
					"Breaks for $broken in $perl_package_name implies Replaces");

				my $replaced_version = $dep_found->{Replaces}{$broken}{version};
				$replaced_version =~ s/-\d+$//; # remove the Debian revision to mirror $broken_version
				is($replaced_version, $broken_version,
					"Replaces version for $broken in $perl_package_name matches Breaks");

				my $provided_version = $providing_dep->{Provides}{$broken}{version};
				$provided_version = '' if !defined $provided_version;
				$provided_version =~ s/-\d+$//; # remove the Debian revision to mirror $broken_version
				is($provided_version, $broken_version,
				    "Provides version for $broken in $perl_package_name matches Breaks");
				if ($provided_version ne $corelist_version) {
					if ($provided_version eq '') {
						diag("s/$broken,/$broken (= $corelist_version),/");
					} else {
						diag("s/$broken (= $provided_version)/$broken (= $corelist_version)/");
					}
				}
			}
		}
	}
}

# finally, also check if there are any (new?) packages in the archive
# that match Module::CoreList
my @found_in_archive;
for my $module (keys %$corelist) {
	my $package = $cpan_from_debian_guess{$module};
	next if grep $deps_found{$_}{$breaksname}{$package}, keys %deps_found;
	next if $is_perl_binary{$package};
	next if $not_in_debian_core{$package};
	push @found_in_archive, $package
		if exists $apt->{$package}
		&& exists $apt->{$package}{VersionList};
}
my $found_in_archive = join(" ", @found_in_archive);
is($found_in_archive, "", "no potential packages for new Provides/Replaces/Breaks found in the archive");

# convert libfoo-bar-perl to Foo::Bar
sub deb2cpan {
	local $_ = shift;
	return $special_modules{$_} if exists $special_modules{$_};
	return $debian_from_cpan_guess{$_} if exists $debian_from_cpan_guess{$_};
	s/^lib(.*)-perl/$1/;
	s/-/::/g;
	s/(\w+)/\u$1/g;
	return $_;
}
			
sub cpan_version_to_deb {
	my $cpan_version = shift;
	my $package = shift;
	my $digits = shift;

	# cpan_version
	#         digits
	#                result
	# 1.15_02,  2 => 1.15.02
	# 1.15_02,  4 => 1.1502
	# 1.15_02,  0 => 1.15.02
	# 
	# 1.15_021, 2 => 1.15.021
	# 1.15_021, 4 => 1.1500.021
	# 1.15_021, 0 => 1.15.021
	#
	# 1.15,	 1 => 1.15
	# 1.15,	 2 => 1.15
	# 1.15,	 4 => 1.1500
	# 1.15,	 0 => 1.15

	return $ok{$package}{$cpan_version} if exists $ok{$package}{$cpan_version};

	# 1.15_02 => (1, 15, 02)
	my ($major, $prefix, $suffix) = ($cpan_version =~ /^(\d+\.)(\d+)(?:_(\d+))?$/);
	die("no match with $cpan_version?") if !$major;

	$suffix ||= "";
	if (length($suffix) + length($prefix) == $digits) {
		$prefix .= $suffix;
		$suffix = "";
	}
	if (length($suffix) + length($prefix) < $digits) {
		$prefix .= "0" while length($prefix) < $digits;
	}
	$suffix = ".$suffix" if $suffix ne "";
	$major.$prefix.$suffix;
}

sub get_archive_upstream_version {
	my $p = shift;
	return if !exists $apt->{$p};
	return if !exists $apt->{$p}{VersionList}; # virtual package
	my $latest = (sort byversion @{$apt->{$p}{VersionList}})[-1];
	my $v = $latest->{VerStr};
	$v =~ s/\+dfsg//;
	$v =~ s/-[^-]+$//;
	return $v;
}

sub parse_epoch_and_digits_from_version {
	my $p = shift;
	my $v = shift;
	if (!defined $v) {
		my $digits = 0;
		my $epoch = 0;
		$digits = $known_digits{$p} if exists $known_digits{$p};
		$epoch  = $known_epochs{$p} if exists $known_epochs{$p};
		return ($epoch, $digits);
	}
	my ($epoch, $major, $prefix, $suffix, $revision) =
		($v =~ /^
			(?:(\d+):)?      # epoch
			((?:\d+\.))+?    # upstream major version x.y.z (ends in .)
			(\d+)            # last part of upstream version
			(?:[._](\d+))?   # possible _xy or .xy suffix for dev versions and the like
			(-[^-]+)?        # Debian revision
		$/x);
	$epoch = 0 if !defined $epoch;
	return ($epoch, length $prefix);
}

sub byversion {
	return $versioning->compare($a->{VerStr}, $b->{VerStr});
}

sub _init_AptPkg {
	# From /usr/share/doc/libapt-pkg-perl/examples/apt-cache
	#
	# initialise the global config object with the default values and
	# setup the $_system object
	$_config->init;
	$_system = $_config->system;
	# supress cache building messages
	$_config->{quiet} = 2;
}

sub get_perl_version {
	# if cwd is a perl source directory, we check the corelist information
	# for that. Otherwise, fall back to the running perl version
	my $perl_version = qx'dpkg-parsechangelog | \
		sed -ne "s/-[^-]\+$//; s/~.*//; s/^Version: *\([0-9]\+:\)*//p"';
	chomp $perl_version;
	$perl_version = version->parse($perl_version || $])->numify;
	note("testing for $perl_version");
	return $perl_version;
}
