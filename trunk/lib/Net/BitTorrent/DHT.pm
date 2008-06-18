package Net::BitTorrent::DHT;
use strict;
use warnings;
{

    BEGIN {
        use version qw[qv];
        our $SVN = q[$Id$];
        our $VERSION = sprintf q[%.3f], version->new(qw$Rev 0$)->numify / 1000;
    }
    use Socket qw[SOL_SOCKET /F_INET/ SOCK_DGRAM SO_REUSEADDR];
    use Digest::SHA qw[sha1];
    use Carp qw[carp];
    use lib q[../../../lib/];
    use Net::BitTorrent::Util qw[:log :bencode :compact];
    use Net::BitTorrent::DHT::Node::Mainline qw[];
    use Net::BitTorrent::DHT::Node::Azureus qw[];
    #use Data::Dump qw[pp];
    {
        my (%socket, %client, %fileno, %tid, %outstanding_queries);
        my (%node_id, %routing_table, %backup_nodes);

        sub new {
            my ($class, $args) = @_;
            my $self = undef;
            if (defined $args->{q[client]}
                and $args->{q[client]}->isa(q[Net::BitTorrent]))
            {   my $node_id = sha1(
                    (join(
                         q[],
                         map {
                             [q[a] .. q[z], q[A] .. q[Z]]->[rand(52)]
                             } 1 .. 300
                     )
                    )
                );
                $self = bless \$node_id, $class;
                $client{$self} = $args->{q[client]};
                $self->_open_socket or return;
                $node_id{$self}       = $node_id;
                $routing_table{$self} = {};
                $tid{$self}           = qq[\0] x 5;    # 26^5 before rollover
                $client{$self}->_set_pulse($self, time);
            }
            return $self;
        }

        sub _open_socket {
            my ($self) = @_;
            $client{$self}->_do_callback(q[log], TRACE,
                     sprintf(q[Entering %s for %s], [caller 0]->[3], $$self));
            socket(my ($_socket), PF_INET, SOCK_DGRAM, getprotobyname(q[udp]))
                or return;
            setsockopt($_socket, SOL_SOCKET, SO_REUSEADDR, pack(q[l], 1))
                or return;
            bind($_socket,
                 pack(q[Sna4x8],
                      AF_INET,
                      $client{$self}->sockport,
                      (pack q[C4], ($client{$self}->sockaddr =~ m[(\d+)]g)))
            ) or return;
            $fileno{$self} = fileno($_socket);
            $socket{$self} = $_socket;
            return $client{$self}->_add_connection($self);
        }
        sub client  { return $client{$_[0]}; }
        sub node_id { return $node_id{$_[0]}; }
        sub _socket { return $socket{$_[0]}; }
        sub _fileno { return $fileno{$_[0]}; }

        sub sockport {
            return (unpack(q[SnC4x8], getsockname($socket{$_[0]})))[1];
        }

        sub sockaddr {
            return join q[.],
                (unpack(q[SnC4x8], getsockname($socket{$_[0]})))[2 .. 5];
        }

        sub _pulse {
            my ($self) = @_;
            warn q[Pulse!];
            {    # get rid of old outgoing packets...
                my @expired_requests = grep {
                    $outstanding_queries{$self}{$_}->{timestamp}
                        < (time - (60 * 5))
                } keys %{$outstanding_queries{$self}};
                while (my $packet = shift @expired_requests) {
                    delete $outstanding_queries{$self}{$packet};
                }
            }
            {    # get rid of old, useless DHT nodes...
                my @expired_nodes = grep {
                    my $timestamp = $routing_table{$self}{$_}->last_seen;
                    ($timestamp < (time - (60 * 30)))
                        or ($timestamp < (time - (60 * 5))
                         and (not defined $routing_table{$self}{$_}->node_id))
                } keys %{$routing_table{$self}};
                while (my $node = shift @expired_nodes) {
                    $backup_nodes{$self} .=
                        compact(join q[:],
                                $routing_table{$self}{$node}->host,
                                $routing_table{$self}{$node}->port);
                    delete $routing_table{$self}{$node};
                }
            }
            my @hosts = sort keys %{$routing_table{$self}};
        NODE: for my $packed_host (@hosts) {
                my $node = $routing_table{$self}{$packed_host};
                if (    (not defined $node->node_id)
                    and ($node->last_seen < (time - (60 * 5))))
                {   delete $routing_table{$self}{$packed_host};
                    next NODE;
                }
                elsif ($node->last_seen < (time - (60 * 15))) {
                    $node->_query_ping;    # ping them again...
                }
                elsif ($node->last_get_peers < (time - (60 * 30))) {
                    for my $session (@{$client{$self}->sessions}) {
                        if (not $session->private) {

                            #$node->_query_announce_peer($session);
                            $node->_query_get_peers($session);
                        }
                    }
                    $node->_query_find_node(pack q[H40], $$self);
                }
            }
            return $client{$self}->_set_pulse($self, time + (60 * 3));
        }

        sub _process_one {
            my ($self, $read, $write) = @_;
            $client{$self}->_do_callback(q[log], TRACE,
                     sprintf(q[Entering %s for %s], [caller 0]->[3], $$self));
            my $packed_host = recv($socket{$self}, my ($data), $read, 0);
            if (defined $packed_host and length $data) {
                my $packet = bdecode $data;
                if (defined $packet and $packet ne $data) {
                    $routing_table{$self}{$packed_host} ||=
                        Net::BitTorrent::DHT::Node::Mainline->new(
                                              {dht         => $self,
                                               packed_host => $packed_host,
                                               node_id     => undef
                                              }
                        );
                    my $node = $routing_table{$self}{$packed_host};
                    if (defined $packet->{q[y]} and $packet->{q[y]} eq q[q]) {
                        my %dispatch = (ping      => \&_parse_query_ping,
                                        find_node => \&_parse_query_find_node,
                                        get_peers => \&_parse_query_get_peers
                        );
                        if (    defined $packet->{q[q]}
                            and defined $dispatch{$packet->{q[q]}})
                        {   $dispatch{$packet->{q[q]}}($self, $node, $packet);
                        }
                        else {    # xxx - do something drastic
                            #use Data::Dump qw[pp];
                            #die q[Unhandled DHT packet: ] . pp $packet;
                        }
                    }
                    elsif (defined $packet->{q[y]}
                           and $packet->{q[y]} eq q[r])
                    {   my %dispatch = (ping      => \&_parse_reply_ping,
                                        find_node => \&_parse_reply_find_node,
                                        get_peers => \&_parse_reply_get_peers
                        );
                        if (defined $packet->{q[r]}) {
                            if (defined $outstanding_queries{$self}
                                {$packet->{q[t]}})
                            {   #use Data::Dump qw[pp];
                                #warn sprintf q[Reply!!!!! %s for %s],
                                #    pp($packet),
                                #    pp($outstanding_queries{$self}
                                #       {$packet->{q[t]}});
                                my $type = $outstanding_queries{$self}
                                    {$packet->{q[t]}}{q[type]};
                                if (defined $dispatch{$type}) {
                                    $dispatch{$type}($self, $node, $packet);
                                }
                                else {    # xxx - do something drastic
                                    #use Data::Dump qw[pp];
                                    #die q[Unhandled DHT reply: ] . pp $packet;
                                }
                                delete $outstanding_queries{$self}
                                    {$packet->{q[t]}};
                            }
                        }
                        else {            # xxx - do something drastic
                            #use Data::Dump qw[pp];
                            #warn q[Unhandled DHT packet: ] . pp $packet;
                        }
                    }
                }
                else {                    # might be AZ... might be garbage... or both.
                    #warn pp $data;
                    if (not defined $routing_table{$self}{$packed_host}  or
                    not $routing_table{$self}{$packed_host}->isa(q[Net::BitTorrent::DHT::Node::Azureus]) ) {
                    $routing_table{$self}{$packed_host} =
                        Net::BitTorrent::DHT::Node::Azureus->new(
                                              {dht         => $self,
                                               packed_host => $packed_host,
                                               node_id     => undef
                                              }
                        );}
                    my $node = $routing_table{$self}{$packed_host};
                    # XXX - Do stuff with the node
                }
            }
            return (length($data), 0);
        }
        sub _parse_query_ping { $_[1]->_reply_ping($_[2]); }
        sub _parse_reply_ping { $_[1]->_parse_reply_ping($_[2]); }

        sub _parse_query_find_node {
            $_[1]->_parse_query_find_node($_[2]);
        }

        sub _parse_query_get_peers {
            $_[1]->_parse_query_get_peers($_[2]);
        }

        sub _parse_reply_find_node {
            $_[1]->_parse_reply_find_node($_[2]);
        }

        sub _parse_reply_get_peers {
            $_[1]->_parse_reply_get_peers($_[2]);
        }

        sub find_nodes {
            my ($self, $target) = @_;
            return [
                sort {
                    ($a->node_id ^ $target) cmp($b->node_id ^ $target)
                    } values %{$routing_table{$self}}
            ]->[0 .. 8];
        }

        sub _send {
            my ($self, $args) = @_;
            $client{$self}->_do_callback(q[log], TRACE,
                     sprintf(q[Entering %s for %s], [caller 0]->[3], $$self));
            return if not defined $args->{q[node]};
            return
                if defined $args->{q[node]}->node_id
                    and $args->{q[node]}->node_id eq $node_id{$self};
            defined(send($socket{$self}, $args->{q[packet]},
                         0,              $args->{q[node]}->packed_host
                    )
            ) or return;
            if (defined $args->{q[t]} and defined $args->{q[type]})
            {    # don't save replies
                $outstanding_queries{$self}{$args->{q[t]}} = {
                                           size => length($args->{q[packet]}),
                                           timestamp => time,
                                           node      => $args->{q[node]},
                                           type      => $args->{q[type]}
                };
            }
            return 1;
        }

        sub _generate_token_id {    # automatic rollover/expansion/etc
            my ($self) = @_;
            my ($len) = ($tid{$self} =~ m[^([a-z]+)]);
            $tid{$self} = (($tid{$self} =~ m[^z*(\0*)$])
                           ? ($tid{$self} =~ m[\0]
                              ? pack(q[a] . (length $tid{$self}),
                                     (q[a] x (length($len || q[]) + 1))
                                  )
                              : (q[a] . (qq[\0] x (length($tid{$self}) - 1)))
                               )
                           : ++$tid{$self}
            );
            return $tid{$self};
        }

        sub add_node {
            my ($self, $node) = @_;
            $client{$self}->_do_callback(q[log], TRACE,
                     sprintf(q[Entering %s for %s], [caller 0]->[3], $$self));
            my ($host, $port) = split q[:], $node, 2;
            my $packed_host = pack(q[Sna4x8],
                                   AF_INET, $port,
                                   join(q[],
                                        map { chr $_ } ($host =~ m[(\d+)]g))
            );

            # XXX - ...we really need to figure out what sort of peer this is
            return $routing_table{$self}{$packed_host} ||=
                Net::BitTorrent::DHT::Node::Mainline->new(
                                              {dht         => $self,
                                               packed_host => $packed_host,
                                               node_id     => undef
                                              }
                );
        }

        sub as_string {
            my ($self, $advanced) = @_;
            $client{$self}->_do_callback(q[log], TRACE,
                     sprintf(q[Entering %s for %s], [caller 0]->[3], $$self));
            my $dump = q[TODO];
            return print STDERR qq[$dump\n] unless defined wantarray;
            return $dump;
        }
        DESTROY {
            my $self = shift;
            delete $socket{$self};
            delete $fileno{$self};
            delete $node_id{$self};
            delete $client{$self};
            delete $tid{$self};
            delete $routing_table{$self};
            delete $backup_nodes{$self};
            delete $outstanding_queries{$self};
            return 1;
        }
    }
}
1;
__END__

=pod

=head1 NAME

Net::BitTorrent::DHT - Mainline (Kademlia based) Distributed Hash Table

=head1 Constructor

=over 4

=item C<new ( [ARGS] )>

Creates a C<Net::BitTorrent::DHT> object.  This constructor should not be
used directly.

=back

=head1 Methods

=over 4

=item C<client ( )>

Returns the L<Net::BitTorrent|Net::BitTorrent> object related to this
peer.

=item C<sockaddr ( )>

Return the address part of the sockaddr structure for the UDP socket.

See also: L<Net::BitTorrent/sockaddr>

=item C<sockport ( )>

Return the port number that the UDP socket is using on the local host.

See also: L<Net::BitTorrent/sockport>

=item C<as_string ( [ VERBOSE ] )>

Returns a 'ready to print' dump of the C<Net::BitTorrent::DHT> object's
data structure.  If called in void context, the structure is printed to
C<STDERR>.

See also: L<Net::BitTorrent/as_string>

=back

=head1 BUGS/TODO

=over 4

=item *

Currently, the routing table is flat.

=back

=head1 Author

Sanko Robinson <sanko@cpan.org> - http://sankorobinson.com/

CPAN ID: SANKO

=head1 License and Legal

Copyright 2008 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl 5.10 (or higher).  See
http://www.perl.com/perl/misc/Artistic.html or the F<LICENSE> file
included with this distribution.

All POD documentation is covered by the Creative Commons Attribution-
Noncommercial-Share Alike 3.0 License
(http://creativecommons.org/licenses/by-nc-sa/3.0/us/).

Neither this module nor the L<Author|/Author> is affiliated with
BitTorrent, Inc.

=for svn $Id$

=cut
