#!/usr/bin/perl -w
use strict;
use warnings;
use ExtUtils::MakeMaker qw[WriteMakefile prompt];

use File::Find;

my @search = qw[t/000_basic/ t/100_data_parsing/
    t/200_classes/ t/400_broken_data/ t/900_etc/];

if (    # http://cpantest.grango.org/wiki/CPANAuthorNotes
    not $ENV{q[AUTOMATED_TESTING]}
    and can_talk_to_ourself()
    and prompt(
        q[
  *****************************************************************
   During the "make test" phase, we may run tests that open ports
   and simulate typical swarms.  By design, no data will be
   transferred to remote systems during these tests.

   NOTE: These tests can be painfully slow and may fail due to
   restrictive firewalling, local weather conditions, or other
   connectivity problems.
  *****************************************************************

Do you want to perform these tests in addition to core tests?], q[no]
    ) =~ m[^\s*(y)]i
    )
{
    push @search, q[t/500_full_swarm/];
}

my @tests;

find sub {
    return if -d $_ or -l $_;
    return unless -T $_;
    return unless $_ =~ m[.+\.t$];
    push @tests, $File::Find::name;
}, @search;

WriteMakefile(
    NAME         => q[Net::BitTorrent],
    AUTHOR       => q[Sanko Robinson <sanko@cpan.org>],
    VERSION_FROM => q[lib/Net/BitTorrent.pm],
    ABSTRACT     => q[BitTorrent peer-to-peer protocol],
    LICENSE      => q[perl],
    PREREQ_PM    => {
        q[Digest::SHA]           => 5.45,    # CORE in 5.10
        q[version]               => 0.50,    # CORE in 5.10
        q[Test::More]            => 0.74,
        q[Time::HiRes]           => 0,
        q[Data::Dumper]          => 0,
        q[English]               => 0,
        q[Class::ISA]            => 0,
        q[Exporter]              => 0,
        q[Config]                => 0,
        q[File::Basename]        => 0,
        q[File::Path]            => 0,
        q[File::Spec::Functions] => 0,
        q[IO::Select]            => 0,
        q[IO::Socket::INET]      => 0,
        q[Carp]                  => 0,
        q[Cwd]                   => 0,
        q[Fcntl]                 => 0,
        q[overload]              => 0,
        q[Encode]                => 0,
        (  $^O eq q[MSWin32]
           ? ( q[Win32API::File] => 0.10,
               q[utf8] => 0  # utf8::is_utf8 internal as of Perl 5.8.1
               )
           : ()
        )
    },
    dist => {
        COMPRESS => q[gzip -9f],
        SUFFIX   => q[.gz],

#PREOP => q[svn commit -m "make dist" && pod2text .\lib\Net\BitTorrent.pm > README]
#PREOP => q[svn commit -m "make dist"]
    },
    test => { TESTS => join q[ ], @tests },

    #SIGN=> 1 # doesn't play nice with my .svn dirs
);

sub can_talk_to_ourself
{    # Check if we should try to run tests that talk to ourself
    system(qq("$^X" t/data/etc/talk-to-ourself.pl));
    return $? ? 0 : 1;
}

# $Id$