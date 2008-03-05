{

    package Net::BitTorrent::Tracker;

    # Honestly, this should be N::B::Session::Tracker::Tier;

    BEGIN {
        use vars qw[$VERSION];
        use version qw[qv];
        our $SVN = q[$Id$];
        our $VERSION = sprintf q[%.3f], version->new(qw$Rev$)->numify / 1000;
    }

    use strict;
    use warnings 'all';
    use List::Util qw[shuffle];
    use Socket;
    use Carp qw[carp croak];

    {
        my (
            %urls,                 %fileno,          %socket,
            %session,              %next_announce,   %next_scrape,
            %connection_timestamp, %scrape_complete, %scrape_incomplete,
            %scrape_downloaded,    %connected,       %queue_outgoing,
            %queue_incoming,       %next_pulse,
        );

        # constructor
        sub new {
            my ($class, $args) = @_;

            my $self = undef;
            if (    defined $args->{q[session]}
                and $args->{q[session]}->isa(q[Net::BitTorrent::Session])
                and defined $args->{q[urls]})
            {
                $self = bless \$args->{q[urls]}, $class;
                $urls{$self}    = shuffle($args->{q[urls]});
                $session{$self} = $args->{q[session]};

                $next_announce{$self}        = time;
                $next_scrape{$self}          = time;
                $connection_timestamp{$self} = 0;
                $scrape_complete{$self}      = 0;
                $scrape_incomplete{$self}    = 0;
                $scrape_downloaded{$self}    = 0;
                $connected{$self}            = 0;
                $next_pulse{$self}           = time;
            }
            return $self;
        }

        # static
        sub urls   { return $urls{+shift}; }
        sub fileno { return $fileno{+shift}; }
        sub socket { return $socket{+shift}; }

        #sub socket {
        #    my ($self, $value) = @_;
        #    return (
        #        defined $value
        #        ? do {
        #            croak(q[socket is protected]) and return
        #              unless caller->isa(__PACKAGE__);
        #            #croak(q[socket is static])
        #            #  if defined $socket{$self};
        #            croak(q[socket is malformed]) and return
        #              unless $value->isa(q[GLOB]);
        #            $socket{$self} = $value;
        #            if ($value) {
        #                $fileno{$self} = CORE::fileno($socket{$self});
        #                $session{$self}->client->add_connection($self);
        #            }
        #            else { $session{$self}->client->remove_connection($self); }
        #          }
        #        : $socket{$self}
        #    );
        #}

        sub session              { return $session{+shift}; }
        sub client               { return $session{+shift}->client; }
        sub connection_timestamp { return $connection_timestamp{+shift}; }
        sub scrape_complete      { return $scrape_complete{+shift}; }
        sub scrape_incomplete    { return $scrape_incomplete{+shift}; }
        sub scrape_downloaded    { return $scrape_downloaded{+shift}; }
        sub connected            { return $connected{+shift}; }
        sub queue_outgoing       { return $queue_outgoing{+shift}; }
        sub queue_incoming       { return $queue_incoming{+shift}; }

        sub next_pulse    { return $next_pulse{+shift}; }
        sub next_announce { return $next_announce{+shift}; }
        sub next_scrape   { return $next_scrape{+shift}; }

        sub pulse {
            my ($self) = @_;
            if (not defined $socket{$self}) {
                if ($next_scrape{$self} <= time) {
                    $self->scrape;
                    $next_scrape{$self} = time + 120;

                }
                elsif ($next_announce{$self} <= time) {
                    $self->announce;
                    $next_announce{$self} = time + 120;
                    $next_pulse{$self}    = time + 125;
                }
            }
            $next_pulse{$self} =
              Net::BitTorrent::Util::min($next_announce{$self},
                $next_scrape{$self});
            return 1;
        }

        sub disconnect {
            my ($self, $reason) = @_;
            close $socket{$self};
            $session{$self}->client->remove_connection($self);
            delete $socket{$self};
            delete $fileno{$self};
            $connected{$self}      = 0;
            $queue_outgoing{$self} = q[];
            $queue_incoming{$self} = q[];
            return 1;
        }

        sub scrape {
            my ($self) = @_;
            if ($urls{$self}->[0] =~ m[^http:]) {
                my $infohash = $session{$self}->infohash;
                my $peer_id  = $session{$self}->client->peer_id;
                $infohash =~ s|(..)|\%$1|g;    # urlencode
                my %query_hash = (
                    q[info_hash] => $infohash,
                    q[peer_id]   => $peer_id
                );
                my $url =
                    $urls{$self}->[0]
                  . ($urls{$self}->[0] =~ m[\?] ? q[&] : q[?])
                  . join q[&], map { sprintf q[%s=%s], $_, $query_hash{$_} }
                  keys %query_hash;
                $url =~ s|/announce([^\/]*?)$|/scrape$1|;

                return $self->_tcp_connect($url);
            }
            elsif ($urls{$self}->[0] =~ m[^udp:]) {
                return $self->_udp_connect;
            }
            else {
                warn q[Unsupported tracker];
            }
            return;
        }

        sub announce {
            my ($self, $event) = @_;
            if ($urls{$self}->[0] =~ m[^http:]) {
                my $infohash = $session{$self}->infohash;
                my $peer_id  = $session{$self}->client->peer_id;
                $infohash =~ s|(..)|\%$1|g;    # urlencode
                my %query_hash = (
                    q[info_hash]  => $infohash,
                    q[peer_id]    => $peer_id,
                    q[port]       => $session{$self}->client->sockport,
                    q[uploaded]   => $session{$self}->uploaded,
                    q[downloaded] => $session{$self}->downloaded,
                    q[left]       => (
                        $session{$self}->piece_size * scalar(
                            grep { not $_->check and $_->priority }
                              @{$session{$self}->pieces}
                        )
                    ),
                    q[key]        => $^T,
                    q[numwant]    => 200,
                    q[compact]    => 1,
                    q[no_peer_id] => 1,
                    (
                        defined($event)
                        ? (q[event] => $event)
                        : ()
                    )
                );

                $self->_tcp_connect(
                        $urls{$self}->[0]
                      . ($urls{$self}->[0] =~ m[\?] ? q[&] : q[?])
                      . (
                        join q[&],
                        map { sprintf q[%s=%s], $_, $query_hash{$_} }
                          keys %query_hash
                      )
                );
            }
            elsif ($urls{$self}->[0] =~ m[^udp:]) {
                $self->_udp_connect;
            }
            else {
                warn q[Unsupported tracker];
            }
            return 1;
        }

        sub _tcp_connect {
            my ($self, $query) = @_;
            my ($protocol, $host, undef, $port, $object) =
              $query =~ m{^([^:/]+)://([^/:]*)(:(\d+))?(/.*)$};
            my $resolve = gethostbyname($host);    # slow
            if (not defined $resolve or length $resolve != 4) { return; }
            $port = $port ? $port : 80;
            my $socket;
            if (
                not CORE::socket(
                    $socket, &PF_INET, &SOCK_STREAM, getprotobyname(q[tcp])
                )
              )
            {
                $self->client->do_callback(q[tracker_error],
                    q[Failed to create socket]);

            }
            elsif (not ioctl($socket, 0x8004667e, pack(q[I], 1))) {
                $self->client->do_callback(q[tracker_error],
                    q[Failed to set socket to non-blocking]);

            }
            elsif (
                not
                setsockopt($socket, SOL_SOCKET, SO_SNDTIMEO, pack('LL', 15, 0))
                or not
                setsockopt($socket, SOL_SOCKET, SO_RCVTIMEO, pack('LL', 15, 0)))
            {
                $self->client->do_callback(q[tracker_error],
                    q[Failed to set socket connection timeout]);

            }
            elsif (
                not connect($socket, pack(q[Sna4x8], &AF_INET, $port, $resolve))
                and $^E
                and ($^E != 10036)
                and ($^E != 10035))
            {
                $self->client->do_callback(q[tracker_error],
                    sprintf q[Failed to connect: %s (%d)],
                    $^E, $^E + 0);

            }
            else {
                $socket{$self} = $socket;
                $fileno{$self} = CORE::fileno($socket{$self});

                $connection_timestamp{$self} = time;

                $queue_outgoing{$self} = join(qq[\015\012],
                    qq[GET $object HTTP/1.0],
                    q[Connection: close],
                    qq[Host: $host:$port],
                    q[Accept: text/plain],
                    q[Accept-Encoding:],
                    qq[User-Agent: Net::BitTorrent/]
                      . $Net::BitTorrent::VERSION,
                    q[],
                    q[]);
                return $session{$self}->client->add_connection($self);
            }
            return;
        }
        sub _tcp_write      { my ($self) = @_; }
        sub _tcp_read       { my ($self) = @_; }
        sub _tcp_disconnect { my ($self) = @_; }

        sub _tcp_parse_data {
            my ($self) = @_;

            my ($head, $body) = split qq[\015\012\015\012],
              $queue_incoming{$self}, 2;
            if ($head and not $body) {
                $body = $head;
                $head = q[HTTP/1.0 200 OK];
            }    # bad server

            my %headers =
              map { my ($k, $v) = split(m[[^\w-]+], $_, 2); $k => $v }
              split(qq[\015\012], $head);
            if (
                (
                    defined($headers{q[Content-Length]})
                    and (length($body) == $headers{q[Content-Length]})
                )
                or (length($body))
              )
            {
                my ($decoded_data) = Net::BitTorrent::Util::bdecode($body);
                if (defined $decoded_data) {
                    if (defined $decoded_data->{q[failure reason]}) {
                        $self->client->do_callback(q[tracker_error],
                            $decoded_data->{q[failure reason]});
                    }
                    elsif (defined $decoded_data->{q[files]}) {
                        my $file_hash =
                          $decoded_data->{q[files]}{pack q[H*],
                            $session{$self}->infohash};
                        $scrape_complete{$self}   = $file_hash->{q[complete]};
                        $scrape_downloaded{$self} = $file_hash->{q[downloaded]};
                        $scrape_incomplete{$self} = $file_hash->{q[incomplete]};
                        $next_scrape{$self}       = Net::BitTorrent::Util::max(
                            (
                                defined $decoded_data->{q[flags]}
                                  {q[min_request_interval]}
                                ? $decoded_data->{q[flags]}
                                  {q[min_request_interval]}
                                : 0
                            ),
                            900
                        ) + time;
                    }
                    else {
                        if (ref $decoded_data->{q[peers]} eq q[ARRAY])
                        {    # Tracker is old and doesn't listen. Handed us
                                # non-compacted peer list
                            $decoded_data->{q[peers]} =
                              Net::BitTorrent::Util::compact(
                                $decoded_data->{q[peers]});
                        }
                        $session{$self}
                          ->append_nodes($decoded_data->{q[peers]});
                        $next_announce{$self} = Net::BitTorrent::Util::max(
                            (
                                defined $decoded_data->{q[interval]}
                                ? $decoded_data->{q[interval]}
                                : 1800
                            ),
                            (
                                defined $decoded_data->{q[min interval]}
                                ? $decoded_data->{q[min interval]}
                                : 0
                            )
                        ) + time;
                    }
                }
                return $self->disconnect;
            }
            return;
        }

        sub _udp_connect {
            my ($self) = @_;
            $self->client->do_callback(q[tracker_error],
                q[UDP trackers are unsupported.]);

            return 0;
        }

        sub _udp_write {
            my ($self) = @_;
            $self->client->do_callback(q[tracker_error],
                q[UDP trackers are unsupported.]);

            return 0;
        }

        sub _udp_read {
            my ($self) = @_;
            $self->client->do_callback(q[tracker_error],
                q[UDP trackers are unsupported.]);

            return 0;
        }

        sub _udp_disconnect {
            my ($self) = @_;
            $self->client->do_callback(q[tracker_error],
                q[UDP trackers are unsupported.]);

            return 0;
        }

        sub _udp_parse_data {
            my ($self) = @_;
            $self->client->do_callback(q[tracker_error],
                q[UDP trackers are unsupported.]);

            return 0;
        }

        sub process_one {
            my ($self, $read, $write) = @_;
            my ($actual_read, $actual_write) = (0, 0);
            if ($write) {
                $actual_write =
                  syswrite($socket{$self},
                    substr($queue_outgoing{$self}, 0, $write, q[]), $write);
                if ($actual_write) {
                    $session{$self}
                      ->client->do_callback(q[tracker_data_out], $self,
                        $actual_write);
                }
                else { $self->disconnect; return (0, 0); }
            }
            if ($read) {
                $actual_read = sysread(
                    $socket{$self},
                    $queue_incoming{$self},
                    $read,
                    (
                        defined $queue_incoming{$self}
                        ? length($queue_incoming{$self})
                        : 0
                    )
                );
                if ($actual_read) {
                    if (not $connected{$self}) { $connected{$self} = 1; }
                    $session{$self}
                      ->client->do_callback(q[tracker_data_in], $self,
                        $actual_read);
                    $self->parse_packet;
                }

                else {
                    $self->disconnect();
                    return (0, 0);
                }
            }
        }

        sub parse_packet {
            my ($self) = @_;
            if    ($urls{$self}->[0] =~ m[^http:]) { $self->_tcp_parse_data; }
            elsif ($urls{$self}->[0] =~ m[^udp:])  { $self->_udp_parse_data; }
            else { die q[Somethin' is wrong!] }
        }

        sub as_string {
            my ($self, $advanced) = @_;

            my @values = (
                $urls{$self}->[0],
                (q[=] x (27 + length($urls{$self}->[0]))),
                ($scrape_complete{$self} + $scrape_incomplete{$self}),
                $scrape_complete{$self},
                $scrape_incomplete{$self},
                $scrape_downloaded{$self},
                $next_scrape{$self} - time,
                $next_announce{$self} - time,
                $next_pulse{$self} - time,
            );

            $_ = (
                sprintf q[%dm %ss%s],
                int(abs($_) / 60),
                abs($_) % 60,
                $_ > 0 ? q[] : q[ ago]
            ) for @values[6 .. 8];

            my $dump = sprintf(<<'END', @values);
Net::BitTorrent::Tracker (%s)
%s
Basic Information:
  Total peers:     %d
  Complete:        %d
  Incomplete:      %d
  Total Downloads: %d
  Next scrape:     %s
  Next announce:   %s
  Next pulse:      %s
END
            if ($advanced) {
                my @adv_values =
                  (scalar(@{$urls{$self}}), join(q[\n    ], @{$urls{$self}}));
                $dump .= sprintf(<<'END', @adv_values);

Advanced Information:
  URL list: (%d)
     %s
END
            }
            return print STDERR qq[$dump\n] unless defined wantarray;
            return $dump;
        }

        DESTROY {    #  DESTROY
            my $self = shift;

            # static
            delete $urls{$self};
            delete $socket{$self};
            delete $session{$self};
            delete $fileno{$self};

            # protected
            delete $next_announce{$self};
            delete $next_scrape{$self};
            delete $connection_timestamp{$self};

            delete $scrape_complete{$self};
            delete $scrape_incomplete{$self};
            delete $scrape_downloaded{$self};
            delete $next_pulse{$self};

            # private
            delete $connected{$self};
            delete $queue_outgoing{$self};
            delete $queue_incoming{$self};
            return 1;
        }
    }
    1;
}
