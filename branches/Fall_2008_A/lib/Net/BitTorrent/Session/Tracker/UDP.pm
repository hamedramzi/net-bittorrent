#!C:\perl\bin\perl.exe 
package Net::BitTorrent::Session::Tracker::UDP;
{
    use strict;      # core as of perl 5
    use warnings;    # core as of perl 5.006

    #
    use Carp qw[carp];                              # core as of perl 5
    use Scalar::Util qw[blessed weaken refaddr];    # core since perl 5.007003
                                                    #
    use version qw[qv];                             # core as of 5.009
    our $SVN = q[$Id$];
    our $UNSTABLE_RELEASE = 0; our $VERSION = sprintf(($UNSTABLE_RELEASE ? q[%.3f_%03d] : q[%.3f]), (version->new((qw$Rev$)[1])->numify / 1000), $UNSTABLE_RELEASE);

    #
    my (@CONTENTS) = \my (
                  %url, %tier,                                # param to new()
                  %socket);
    my %REGISTRY;

    #
    sub new {
        my ($class, $args) = @_;
        my $self;
        if (not defined $args) {
            carp __PACKAGE__ . q[->new() requires params];
            return;
        }
        if (not defined $args->{q[URL]}) {
            carp __PACKAGE__ . q[->new() requires a 'URL' param];
            return;
        }
        if ($args->{q[URL]} !~ m[^udp://]i) {
            carp
                sprintf(
                  q[%s->new() doesn't know what to do with malformed url: %s],
                  __PACKAGE__, $args->{q[URL]});
            return;
        }
        if (not defined $args->{q[Tier]}) {
            carp __PACKAGE__ . q[->new() requires a 'Tier' param];
            return;
        }
        if (not $args->{q[Tier]}->isa(q[Net::BitTorrent::Session::Tracker])) {
            carp __PACKAGE__ . q[->new() requires a blessed Tracker 'Tier'];
            return;
        }

        #
        $self = bless \$args->{q[URL]}, $class;

        #
        $url{refaddr $self}  = $args->{q[URL]};
        $tier{refaddr $self} = $args->{q[Tier]};
        weaken $tier{refaddr $self};
        weaken($REGISTRY{refaddr $self} = $self);

        #
        return $self;
    }

    sub _announce {
        my ($self, $event) = @_;
        if (defined $event) {
            if ($event !~ m[([started|stopped|complete])]) {
                carp sprintf q[Invalid event for announce: %s], $event;
                return;
            }
        }
        warn sprintf q[UDP!!!!!!!!!!!!!!!!!!!! | %s|%s], $self, $event;
    }

    sub _as_string {
        my ($self, $advanced) = @_;
        my $dump = q[TODO];
        return print STDERR qq[$dump\n] unless defined wantarray;
        return $dump;
    }

    sub CLONE {
        for my $_oID (keys %REGISTRY) {

            #  look under oID to find new, cloned reference
            my $_obj = $REGISTRY{$_oID};
            my $_nID = refaddr $_obj;

            #  relocate data
            for (@CONTENTS) {
                $_->{$_nID} = $_->{$_oID};
                delete $_->{$_oID};
            }

            # do some silly stuff to avoid user mistakes
            #weaken($_client{$_nID} = $_client{$_oID});
            weaken tier {$_nID};

            #  update he weak refernce to the new, cloned object
            weaken($REGISTRY{$_nID} = $_obj);
            delete $REGISTRY{$_oID};
        }
        return 1;
    }

    # Destructor
    DESTROY {
        my ($self) = @_;

        #warn q[Goodbye, ] . $$self;
        # Clean all data
        for (@CONTENTS) {
            delete $_->{refaddr $self};
        }
        delete $REGISTRY{refaddr $self};

        #
        return 1;
    }

    #
    1;
}

=pod

=head1 NAME

Net::BitTorrent::Session::Tracker::UDP - Single UDP BitTorrent Tracker

=head1 Constructor

=over 4

=item C<new ( [ARGS] )>

Creates a C<Net::BitTorrent::Session::Tracker::UDP> object.  This
constructor should not be used directly.

=back

=head1 BUGS/TODO

=over 4

=item *

...this doesn't work.  Yet.

=back

=head1 Author

Sanko Robinson <sanko@cpan.org> - http://sankorobinson.com/

CPAN ID: SANKO

=head1 License and Legal

Copyright (C) 2008 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>

This program is free software; you can redistribute it and/or modify
it under the terms of The Artistic License 2.0.  See the F<LICENSE>
file included with this distribution or
http://www.perlfoundation.org/artistic_license_2_0.  For
clarification, see http://www.perlfoundation.org/artistic_2_0_notes.

When separated from the distribution, all POD documentation is covered
by the Creative Commons Attribution-Share Alike 3.0 License.  See
http://creativecommons.org/licenses/by-sa/3.0/us/legalcode.  For
clarification, see http://creativecommons.org/licenses/by-sa/3.0/us/.

Neither this module nor the L<Author|/Author> is affiliated with
BitTorrent, Inc.

=for svn $Id$

=cut
