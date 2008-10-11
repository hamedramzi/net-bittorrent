#!C:\perl\bin\perl.exe 
package Net::BitTorrent::Session;
{
    use strict;      # core as of perl 5
    use warnings;    # core as of perl 5.006

    #
    use Digest::SHA qw[sha1_hex];                   # core as of perl 5.009003
    use Carp qw[carp carp];                         # core as of perl 5
    use Cwd qw[cwd];                                # core as of perl 5
    use File::Spec::Functions qw[rel2abs catfile];  # core as of perl 5.00504
    use Scalar::Util qw[blessed weaken refaddr];            # core as of perl 5.007003
    use List::Util qw[sum shuffle max];                 # core as of perl 5.007003
    use Fcntl qw[O_RDONLY];                         # core as of perl 5

    #
    use lib q[../../../lib];
    use Net::BitTorrent::Util qw[:bencode :compact];
    use Net::BitTorrent::Session::File;
    use Net::BitTorrent::Session::Tracker;
    use Net::BitTorrent::Peer;

    #
    use version qw[qv];                             # core as of 5.009
    our $SVN = q[$Id$];
    our $UNSTABLE_RELEASE = 0; our $VERSION = sprintf(($UNSTABLE_RELEASE ? q[%.3f_%03d] : q[%.3f]), (version->new((qw$Rev$)[1])->numify / 1000), $UNSTABLE_RELEASE);

    # Debugging
    #use Data::Dump qw[pp];
    #
    my (%_client, %path, %basedir);    # new() params (basedir is optional)
    my (%size,          %files,  %trackers, %infohash,
        %_private,      %pieces, %uploaded, %downloaded,
        %_piece_length, %nodes,  %bitfield, %working_pieces,
        %_block_length
    );
    my (%clutter);    # creation date, encoding, created by, etc.

    # Constructor
    sub new {

        # Creates a new N::B::Session object
        # Accepts parameters as key/value pairs in a hash reference
        # Required parameters:
        #  - Client  (blessed N::B object)
        #  - Path    (.torrent)
        # Optional parameters
        #  - BaseDir (root directory for related files; defaults to cwd)
        # Returns
        #    - a new blessed object on success
        #    - undef on failure
        # MO
        # - validate incoming parameters
        # - read .torrent
        # - bdecode data
        # - validate pieces string
        # - get infohash
        # - verify infohash is valid
        # - bless $self
        # - set client
        # - set clutter
        # - if multifile
        #   - loop through each file
        #     - add size to toal length
        #     - create new N::B::S::File object
        # - else
        #   - length is total length
        #   - create new N::B::S::File object
        # - set tracker hash
        # - set pieces hash
        # -
        # -
        # -
        # -
        # -
        # - return $self
        my ($class, $args) = @_;
        my $self;

        # Param validation... Ugh...
        if (not defined $args) {
            carp q[Net::BitTorrent::Session->new({}) requires ]
                . q[a set of parameters];
            return;
        }
        if (ref($args) ne q[HASH]) {
            carp q[Net::BitTorrent::Session->new({}) requires ]
                . q[parameters to be passed as a hashref];
            return;
        }
        if (not defined $args->{q[Path]}) {
            carp q[Net::BitTorrent::Session->new({}) requires a ]
                . q['Path' parameter];
            return;
        }
        if (not -f $args->{q[Path]}) {
            carp
                sprintf(q[Net::BitTorrent::Session->new({}) cannot find '%s'],
                        $args->{q[Path]});
            return;
        }
        if (not defined $args->{q[Client]}) {
            carp q[Net::BitTorrent::Session->new({}) requires a ]
                . q['Client' parameter];
            return;
        }
        if (not blessed $args->{q[Client]}) {
            carp q[Net::BitTorrent::Session->new({}) requires a ]
                . q[blessed 'Client' object];
            return;
        }
        if (not $args->{q[Client]}->isa(q[Net::BitTorrent])) {
            carp q[Net::BitTorrent::Session->new({}) requires a ]
                . q[blessed Net::BitTorrent object in the 'Client' parameter];
            return;
        }
        if (defined $args->{q[BlockLength]}) {    # Undocumented
            if ($args->{q[BlockLength]} !~ m[^\d+$]) {
                carp q[Net::BitTorrent::Session->new({}) requires an ]
                    . q[integer 'BlockLength' parameter];
                delete $args->{q[BlockLength]};
            }
        }

        # Tidy up some rough edges here
        $args->{q[Path]} = rel2abs($args->{q[Path]});
        $args->{q[BaseDir]} = rel2abs(
                  defined($args->{q[BaseDir]}) ? $args->{q[BaseDir]} : cwd());

        # Here comes the real work...
        my ($TORRENT_FH, $TORRENT_RAW, $TORRENT_DATA);

        # Open .torrent
        if (not sysopen($TORRENT_FH, $args->{q[Path]}, O_RDONLY)) {
            carp    # difficult to trigger for a test suite
                sprintf(
                 q[Net::BitTorrent::Session->new({}) could not open '%s': %s],
                 $args->{q[Path]}, $!);
            return;
        }

        # No need to lock it...
        # Read .torrent
        if (sysread($TORRENT_FH, $TORRENT_RAW, -s $args->{q[Path]})
            != -s $args->{q[Path]})
        {   carp    # difficult to trigger for a test suite
                sprintf(
                q[Net::BitTorrent::Session->new({}) could not read all %d bytes of '%s' (Read %d instead)],
                -s $args->{q[Path]},
                $args->{q[Path]}, length($TORRENT_DATA)
                );
            return;
        }

        # Close .torrent
        if (not close($TORRENT_FH)) {
            carp    # difficult to trigger for a test suite
                sprintf(
                q[Net::BitTorrent::Session->new({}) could not close '%s': %s],
                $args->{q[Path]}, $!);
            return;
        }

        #
        undef $TORRENT_FH;

        # bdecode data
        $TORRENT_DATA = bdecode($TORRENT_RAW);
        undef $TORRENT_RAW;

        #
        if (not defined $TORRENT_DATA) {
            carp q[Malformed .torrent];
            return;
        }

        #warn pp $TORRENT_DATA->{q[info]}{q[files]};
        #warn $args->{q[Path]};
        # parse pieces string and...
        #   - verify pieces string > 40
        #   - verify pieces string % 40 == 0
        if (length(unpack(q[H*], $TORRENT_DATA->{q[info]}{q[pieces]})) < 40)
        {    # TODO: Create bad .torrent to trigger this for tests
                #$_client{refaddr $self}
                #    ->_event(q[log], {Level=>ERROR, Msg=>q[Broken torrent: Pieces hash is less than 40 bytes]});
            return;
        }
        if (length(unpack(q[H*], $TORRENT_DATA->{q[info]}{q[pieces]})) % 40)
        {       # TODO: Create bad .torrent to trigger this for tests
                #$_client{refaddr $self}
                #    ->_event(q[log], {Level=>ERROR, Msg=>q[Broken torrent: Pieces hash will not break apart into even, 40 byte segments]});
            return;
        }

        # Get infohash
        my $infohash = sha1_hex(bencode($TORRENT_DATA->{q[info]}));

        # Verify infohash is valid
        if ($infohash !~ m[^([0-9a-f]{40})$]) {

            # Could this ever really happen?
            #$_client{refaddr $self}->_event(q[log], {Level=>ERROR,
            #                             Msg=>q[Improper info_hash]});
            return;
        }

        # Bless $self
        $self = bless \$infohash, $class;

        # Store required and extra data
        #
        # What data should I store in its own hash?
        #  - Yes
        #    - infohash
        #    - info/private
        #    - info/piece length
        #    - info/pieces
        #    - announce || announce-list
        #  - Possible (until I decide, they are put into %clutter)
        #    - comment
        #    - encoding
        #    - created by
        #    - creation date
        #    ? info/name
        #    -
        $_client{refaddr $self} = $args->{q[Client]};
        weaken $_client{refaddr $self};
        $infohash{refaddr $self}       = $infohash;
        $_private{refaddr $self}       = $TORRENT_DATA->{q[info]}{q[private]} ? 1 : 0;
        $_piece_length{refaddr $self}  = $TORRENT_DATA->{q[info]}{q[piece length]};
        $pieces{refaddr $self}         = $TORRENT_DATA->{q[info]}{q[pieces]};
        $bitfield{refaddr $self}       = pack(q[b*], qq[\0] x $self->_piece_count);
        $path{refaddr $self}           = $args->{q[Path]};
        $working_pieces{refaddr $self} = {};
        $_block_length{refaddr $self} = (defined $args->{q[BlockLength]}
                                 ? $args->{q[BlockLength]}
                                 : (2**14)
        );
        $nodes{refaddr $self} = q[];

        #warn pp $TORRENT_DATA;
        # Stuff we may eventually handle
        $clutter{refaddr $self} = {
            q[created by]    => $TORRENT_DATA->{q[created by]},
            q[creation date] => $TORRENT_DATA->{q[creation date]},
            q[comment]       => $TORRENT_DATA->{q[comment]},
            q[encoding]      => $TORRENT_DATA->{q[encoding]},
            q[nodes]         => $TORRENT_DATA->{q[nodes]},           # DHT
            q[sources]   => $TORRENT_DATA->{q[sources]},     # Depthstrike
            q[url-list]  => $TORRENT_DATA->{q[url-list]},    # GetRight
            q[httpseeds] => $TORRENT_DATA->{q[httpseeds]}    # BitTornado
        };

        #warn pp \%clutter;
        # Files
        $size{refaddr $self} = 0;
        if (defined $TORRENT_DATA->{q[info]}{q[files]}) { # multifile .torrent
            for my $file (@{$TORRENT_DATA->{q[info]}{q[files]}}) {
                $size{refaddr $self} += $file->{q[length]};
                my $filename = catfile(
                    $args->{q[BaseDir]},
                    (    #defined($TORRENT_DATA->{q[info]}{q[name.utf-8]})
                           #? $TORRENT_DATA->{q[info]}{q[name.utf-8]}
                           #:
                       $TORRENT_DATA->{q[info]}{q[name]}
                    ),
                    @{  (    #defined($file->{q[path.utf-8]})
                             #? $file->{q[path.utf-8]}
                             #:
                         $file->{q[path]}
                        )
                        }
                );
                if (    defined $TORRENT_DATA->{q[encoding]}
                    and $TORRENT_DATA->{q[encoding]} !~ m[^utf-?8$]i
                    and not utf8::is_utf8($filename)
                    and require Encode)
                {  # some clients do a poor/incomplete job with encoding so we
                       # work around it by upgrading and setting the utf8 flag
                    $filename =
                        Encode::decode(Encode::find_encoding(
                                                  $TORRENT_DATA->{q[encoding]}
                                           )->name,
                                       $filename
                        );
                }
                push(@{$files{refaddr $self}},
                     Net::BitTorrent::Session::File->new(
                                         {Size    => $file->{q[length]},
                                          Path    => $filename,
                                          Session => $self,
                                          Index   => scalar(@{$files{refaddr $self}})
                                         }
                     )
                );
            }
        }
        else {    # single file .torrent
            my $filename = catfile(
                $args->{q[BaseDir]},
                (    #defined($TORRENT_DATA->{q[info]}{q[name.utf-8]})
                       #? $TORRENT_DATA->{q[info]}{q[name.utf-8]}
                       #:
                   $TORRENT_DATA->{q[info]}{q[name]}
                )
            );
            if (    defined $TORRENT_DATA->{q[encoding]}
                and $TORRENT_DATA->{q[encoding]} !~ m[^utf-?8$]i
                and not utf8::is_utf8($filename)
                and require Encode)
            {    # some clients do a poor/incomplete job with encoding so we
                    # work around it by upgrading and setting the utf8 flag
                $filename =
                    Encode::decode(Encode::find_encoding(
                                                  $TORRENT_DATA->{q[encoding]}
                                       )->name,
                                   $filename
                    );
            }

            #warn sprintf q['%s' is utf? %d], $filename,
            #    utf8::is_utf8($filename);
            push(@{$files{refaddr $self}},
                 Net::BitTorrent::Session::File->new(
                              {Size    => $TORRENT_DATA->{q[info]}{q[length]},
                               Path    => $filename,
                               Session => $self,
                               Index   => 0
                              }
                 )
            );
            $size{refaddr $self} = $TORRENT_DATA->{q[info]}{q[length]};
        }

        # Trackers
        if (defined $TORRENT_DATA->{q[announce-list]}) {    # Multitracker
            for my $tier (@{$TORRENT_DATA->{q[announce-list]}}) {
                push(@{$trackers{refaddr $self}},
                     Net::BitTorrent::Session::Tracker->new(
                                             {Session => $self, URLs => $tier}
                     )
                );
            }
        }
        elsif (defined $TORRENT_DATA->{q[announce]}) {      # Single tracker
            push(@{$trackers{refaddr $self}},
                 Net::BitTorrent::Session::Tracker->new(
                                    {Session => $self,
                                     URLs    => [$TORRENT_DATA->{q[announce]}]
                                    }
                 )
            );
        }
        else {    # No trackers; requires DHT
            $trackers{refaddr $self} = [];
            if ($_private{refaddr $self}) {  # I'm not sure how to handle this.  We...
                 # could resort to Webseeding but... why would anyone do this?
                carp q[This torrent does not contain any trackers and does ]
                    . q[not allow DHT];
                return;
            }
        }

        #
        #warn pp \%size;
        #warn pp \%files;
        #warn pp \%trackers;
        $_client{refaddr $self}->_schedule({Time   => time + 15,
                                    Code   => sub { shift->_new_peer },
                                    Object => $self
                                   }
        );
        return $self;
    }

    # Accessors | Public
    sub infohash { return $infohash{refaddr +shift} }
    sub trackers { return $trackers{refaddr +shift} }
    sub bitfield { return $bitfield{refaddr +shift} }
    sub path     { return $path{refaddr +shift} }
    sub files    { return $files{refaddr +shift} }
    sub size     { return $size{refaddr +shift} }

    # Accessors | Private
    sub _client       { return $_client{refaddr +shift}; }
    sub _uploaded     { return $uploaded{refaddr +shift} || 0; }
    sub _downloaded   { return $downloaded{refaddr +shift} || 0; }
    sub _piece_length { return $_piece_length{refaddr +shift}; }
    sub _private      { return $_private{refaddr +shift}; }
    sub _block_length { return $_block_length{refaddr +shift} }

    sub _complete {
        my ($self) = @_;
        return ((substr(unpack(q[b*], $self->_wanted), 0, $self->_piece_count)
                     !~ 1
                ) ? 1 : 0
        );
    }

    sub _piece_count {
        return int(length(unpack(q[H*], $pieces{refaddr +shift})) / 40);
    }
    sub _compact_nodes { return $nodes{refaddr +shift}; }

    sub _wanted {
        my ($self) = @_;
        my $wanted = q[0] x $self->_piece_count;
        my $p_size = $_piece_length{refaddr $self};
        my $offset = 0;
        for my $file (@{$files{refaddr $self}}) {

        #    warn sprintf q[[i%d|p%d|s%d] %s ], $file->index, $file->priority,
        #    $file->size, $$file;
            my $start = ($offset / $p_size);
            my $end   = (($offset + $file->size) / $p_size);

            #warn sprintf q[%d .. %d | %d], ($start + ($start > int($start))),
            #    ($end + ($end > int($end))), ($end - $start + 1);
            if ($file->priority ? 1 : 0) {
                substr($wanted, $start,
                       ($end - $start + 1),
                       (($file->priority ? 1 : 0) x ($end - $start + 1)));
            }

            #warn $wanted;
            $offset += $file->size;
        }

        #my $relevence = $peer->_bitfield | $_wanted ^ $_wanted;
        return (pack(q[b*], $wanted) | $bitfield{refaddr $self} ^ $bitfield{refaddr $self});
    }

    # Methods | Public
    # ...None yet?
    # Methods | Private
    sub _add_uploaded {
        my ($self, $amount) = @_;
        $uploaded{refaddr $self} += (($amount =~ m[^\d+$]) ? $amount : 0);
    }

    sub _add_downloaded {
        my ($self, $amount) = @_;
        $downloaded{refaddr $self} += (($amount =~ m[^\d+$]) ? $amount : 0);
    }

    sub _append_compact_nodes {
        my ($self, $nodes) = @_;
        if (not $nodes) { return; }
        $nodes{refaddr $self} ||= q[];
        return $nodes{refaddr $self} = compact(uncompact($nodes{refaddr $self} . $nodes));
    }

    sub _new_peer {
        my ($self) = @_;

        #
        $_client{refaddr $self}->_schedule({Time   => time + 15,
                                    Code   => sub { shift->_new_peer },
                                    Object => $self
                                   }
        );

 #
 #         warn sprintf q[Half open peers: %d | Total: %d], scalar(
 #~             grep {
 #~                 $_->{q[Object]}->isa(q[Net::BitTorrent::Peer])
 #~                     and not defined $_->{q[Object]}->peerid()
 #~                 } values %{$_client{refaddr $self}->_connections}
 #~             ),
 #~             scalar(grep { $_->{q[Object]}->isa(q[Net::BitTorrent::Peer]) }
 #~                    values %{$_client{refaddr $self}->_connections});
 #
        if (scalar(
                grep {
                    $_->{q[Object]}->isa(q[Net::BitTorrent::Peer])
                        and not defined $_->{q[Object]}->peerid
                    } values %{$_client{refaddr $self}->_connections}
            ) >= 8
            )
        {   return;
        }    # half open
        if ($self->_complete)  { return; }
        if (not $nodes{refaddr $self}) { return; }

        #
        my @nodes = uncompact($nodes{refaddr $self});

        #
        for (1 .. (30 - scalar @{$self->_peers})) {
            last if not @nodes;

            #
            my $node = shift @nodes;

            #
            my $ok
                = $_client{refaddr $self}->_event(q[ip_filter], {Address => $node});
            if (defined $ok and $ok == 0) { next; }

            #
            my $peer =
                Net::BitTorrent::Peer->new({Address => $node,
                                            Session => $self
                                           }
                );
            last
                if scalar(
                grep {
                    $_->{q[Object]}->isa(q[Net::BitTorrent::Peer])
                        and not defined $_->{q[Object]}->peerid
                    } values %{$_client{refaddr $self}->_connections}
                ) >= 8;
        }

        #
        return 1;
    }

    sub _peers {
        my ($self) = @_;

        #
        my @return = map {
            (    ($_->{q[Object]}->isa(q[Net::BitTorrent::Peer]))
             and ($_->{q[Object]}->_session)
             and ($_->{q[Object]}->_session eq $self))
                ? $_->{q[Object]}
                : ()
        } values %{$_client{refaddr $self}->_connections};

        #
        return \@return;
    }

    sub _add_tracker {
        my ($self, $tier) = @_;
        carp q[Please, pass new tier in an array ref...]
            unless ref $tier eq q[ARRAY];
        return
            push(@{$trackers{refaddr $self}},
                 Net::BitTorrent::Session::Tracker->new(
                                             {Session => $self, URLs => $tier}
                 )
            );
    }

    sub _piece_by_index {
        my ($self, $index) = @_;

        #
        if (not defined $index) {
            carp
                q[Net::BitTorrent::Session->_piece_by_index() requires an index];
            return;
        }

        #
        if ($index !~ m[^\d+$]) {
            carp
                q[Net::BitTorrent::Session->_piece_by_index() requires a positive integer];
            return;
        }

        #
        if (defined $working_pieces{refaddr $self}{$index}) {
            return $working_pieces{refaddr $self}{$index};
        }

        #
        return;
    }

    sub _pick_piece {
        my ($self, $peer) = @_;

        # TODO: param validation
        if (not defined $peer) {
            carp
                q[Net::BitTorrent::Session->_pick_piece(PEER) requires a peer];
        }
        if (not blessed $peer) {
            carp
                q[Net::BitTorrent::Session->_pick_piece(PEER) requires a blessed peer];
        }
        if (not $peer->isa(q[Net::BitTorrent::Peer])) {
            carp
                q[Net::BitTorrent::Session->_pick_piece(PEER) requires a peer object];
        }

        #
        #use Data::Dump qw[pp];
        #warn q[_pick_piece ]. pp $working_pieces{refaddr $self};
        #
        my $piece;

        # pieces this peer has and we need
        my $_wanted   = $self->_wanted;
        my $relevence = $peer->_bitfield & $_wanted;

        #
        return if unpack(q[b*], $relevence) !~ m[1];

        #
        my $endgame = (    # XXX - make this a percentage variable
            (sum(split(q[], unpack(q[b*], $_wanted)))
                 <= (length(unpack(q[b*], $_wanted)) * 0.01)
            )
            ? 1
            : 0
        );

    #
    # block_per_piece = 35
    # pieces          = 5
    # slots           = 20
    # unchoked_peers  = 10
    #
    # (block_size * pieces) <= (peers * 20)
    # (((blocks_per_piece * pieces) / slots) * peers) = 5
    # working = ((blocks_per_piece / slots)  * peers)
    #
    #  There should be, at least, ($slots * $peers) blocks.
    #  $working = int ( ( $slots * $unchoked_peers ) / $blocks_per_piece ) + 1
    #  $working = int ( ( 20     * 8               ) / 35                ) + 1
    #
        my $slots = int(((2**21) / $_piece_length{refaddr $self}));    # ~2M/peer
        my $unchoked_peers
            = scalar(grep { $_->_peer_choking == 0 } @{$self->_peers});
        my $blocks_per_piece = int($_piece_length{refaddr $self} / (
                                               ($_piece_length{refaddr $self} < 2**14)
                                               ? $_piece_length{refaddr $self}
                                               : 2**14
                                   )
        );
        my $max_working_pieces
            = max(3,int(($slots * $unchoked_peers) / $blocks_per_piece) + 1);

        #warn sprintf q[$max_working_pieces: %d], $max_working_pieces;
        #
        if (scalar(
                  grep { $_->{q[Slow]} == 0 } values %{$working_pieces{refaddr $self}}
            ) >= $max_working_pieces
            )
        {

            #warn sprintf q[%d>=%d], (scalar(keys %{$working_pieces{refaddr $self}})),
            #    $max_working_pieces;
            my @indexes = grep { $working_pieces{refaddr $self}{$_}->{q[Slow]} == 0 }
                keys %{$working_pieces{refaddr $self}};

            #warn sprintf q[indexes: %s], (join q[, ], @indexes);
            for my $index (@indexes) {
                if (vec($relevence, $index, 1) == 1) {
                    if (($endgame
                         ? index($working_pieces{refaddr $self}{$index}
                                     {q[Blocks_Recieved]},
                                 0,
                                 0
                         )
                         : scalar grep { scalar keys %$_ }
                         @{  $working_pieces{refaddr $self}{$index}
                                 {q[Blocks_Requested]}
                         }
                        ) != -1
                        )
                    {   $piece = $working_pieces{refaddr $self}{$index};
                        last;
                    }
                }
            }
        }
        else {

            #warn sprintf q[%d<%d], (scalar(keys %{$working_pieces{refaddr $self}})),
            #    $max_working_pieces;
            my @wanted;
            for my $i (0 .. ($self->_piece_count - 1))
            {    # XXX - Far from efficient...
                push @wanted, $i if vec($relevence, $i, 1);
            }
            @wanted = shuffle @wanted;    # XXX - use priorities...
        TRY: for my $try (1 .. 10) {
                my $index = shift @wanted;
                next TRY if vec($relevence, $index, 1) == 0;
                my $_piece_length = (    # XXX - save some time and store this
                    ($index == int($size{refaddr $self} / $_piece_length{refaddr $self}))
                    ? ($size{refaddr $self} % $_piece_length{refaddr $self})
                    : ($_piece_length{refaddr $self})
                );

                #
                my $block_length = (
                               ($_piece_length{refaddr $self} < $_block_length{refaddr $self})
                               ? ($_piece_length{refaddr $self})
                               : $_block_length{refaddr $self}
                );
                my $block_length_last
                    = ($_piece_length{refaddr $self} % $_piece_length);

                #die $block_length_last;
                # XXX - may not be balanced
                my $block_count
                    = (int($_piece_length / $block_length)
                           + ($block_length_last ? 1 : 0));

                #
                $piece = {
                    Index    => $index,
                    Priority => 2,        # Get from file
                    Blocks_Requested => [map { {} } 1 .. $block_count],
                    Blocks_Recieved => [map {0} 1 .. $block_count],
                    Block_Length    => $block_length,
                    Block_Length_Last => $block_length_last,
                    Block_Count       => $block_count,
                    Length            => $_piece_length,
                    Endgame           => $endgame,
                    Slow              => 0,
                    Touch             => 0
                };
                last TRY;
            }
        }

        #
        if ($piece) {
            if (not defined $working_pieces{refaddr $self}{$piece->{q[Index]}}) {
                $working_pieces{refaddr $self}{$piece->{q[Index]}} = $piece;
            }
        }

        #
        return $piece ? $working_pieces{refaddr $self}{$piece->{q[Index]}} : ();
    }

    sub _write_data {
        my ($self, $index, $offset, $data) = @_;

        # TODO: param validation
        if ((length($$data) + (($_piece_length{refaddr $self} * $index) + $offset))
            > $size{refaddr $self})
        {   carp q[Too much data or bad offset data for this torrent];
            return;
        }

        #
        my $file_index = 0;
        my $total_offset
            = int((($index * $_piece_length{refaddr $self})) + ($offset || 0));

        #warn sprintf q[Write I:%d O:%d L:%d TOff:%d], $index, $offset,
        #    length($$data), $total_offset;
    SEARCH:
        while ($total_offset > $files{refaddr $self}->[$file_index]->size) {
            $total_offset -= $files{refaddr $self}->[$file_index]->size;
            $file_index++;
            last SEARCH    # XXX - should this simply return?
                if not defined $files{refaddr $self}->[$file_index]->size;
        }
    WRITE: while (length $$data > 0) {
            my $this_write
                = ($total_offset + length $$data
                   > $files{refaddr $self}->[$file_index]->size)
                ? $files{refaddr $self}->[$file_index]->size - $total_offset
                : length $$data;
            $files{refaddr $self}->[$file_index]->_open(q[w]) or return;
            $files{refaddr $self}->[$file_index]->_sysseek($total_offset);
            $files{refaddr $self}->[$file_index]
                ->_write(substr($$data, 0, $this_write, q[]))
                or return;
            $file_index++;
            last WRITE if not defined $files{refaddr $self}->[$file_index];
            $total_offset = 0;
        }

        #
        return 1;
    }

    sub _read_data {
        my ($self, $index, $offset, $length) = @_;

        #
        carp q[Bad index!]  if not defined $index  || $index !~ m[^\d+$];
        carp q[Bad offset!] if not defined $offset || $offset !~ m[^\d+$];
        carp q[Bad length!] if not defined $length || $length !~ m[^\d+$];

        #
        my $data = q[];
        if (($length + (($_piece_length{refaddr $self} * $index) + $offset))
            > $size{refaddr $self})
        {   carp q[Too much or bad offset data for this torrent];
            return;
        }

        #
        my $file_index = 0;
        my $total_offset
            = int((($index * $_piece_length{refaddr $self})) + ($offset || 0));

        #warn sprintf q[Read  I:%d O:%d L:%d TOff:%d], $index, $offset,
        #    $length, $total_offset;
    SEARCH:
        while ($total_offset > $files{refaddr $self}->[$file_index]->size) {
            $total_offset -= $files{refaddr $self}->[$file_index]->size;
            $file_index++;
            last SEARCH    # XXX - should this simply return?
                if not defined $files{refaddr $self}->[$file_index]->size;
        }
    READ: while ($length > 0) {
            my $this_read
                = (($total_offset + $length)
                   >= $files{refaddr $self}->[$file_index]->size)
                ? ($files{refaddr $self}->[$file_index]->size - $total_offset)
                : $length;

            #warn sprintf q[Reading %d (%d) bytes from '%s'],
            #    $this_read, $this_write, $files{refaddr $self}->[$file_index]->path;
            $files{refaddr $self}->[$file_index]->_open(q[r]) or return;
            $files{refaddr $self}->[$file_index]->_sysseek($total_offset);
            $data .= $files{refaddr $self}->[$file_index]->_read($this_read);

            #
            $file_index++;
            $length -= $this_read;
            last READ if not defined $files{refaddr $self}->[$file_index];
            $total_offset = 0;
        }

        #
        return \$data;
    }

    sub hashcheck {
        my ($self) = @_;
        for my $index (0 .. ($self->_piece_count - 1)) {
            $self->_check_piece_by_index($index);
        }
        return 1;
    }

    sub _check_piece_by_index {
        my ($self, $index) = @_;

        #
        if (not defined $index) {
            carp q[Net::BitTorrent::Session->_check_piece_by_index( INDEX ) ]
                . q[requires an index.];
            return;
        }
        if ($index !~ m[^\d+$]) {
            carp q[Net::BitTorrent::Session->_check_piece_by_index( INDEX ) ]
                . q[requires an integer index.];
            return;
        }

        #
        if (defined $working_pieces{refaddr $self}{$index}) {
            delete $working_pieces{refaddr $self}{$index};

            #if (keys %{$working_pieces{refaddr $self}}) {
            #    warn q[Remaining working pieces: ]
            #        . pp $working_pieces{refaddr $self};
            #}
        }

        #
        my $data = $self->_read_data($index, 0,
                                     ($index == ($self->_piece_count - 1)
                                      ? ($size{refaddr $self} % $_piece_length{refaddr $self})
                                      : $_piece_length{refaddr $self}
                                     )
        );

        #
        #warn sprintf q[%s vs %s],
        #     sha1_hex($data),
        #     substr(unpack(q[H*], $pieces{refaddr $self}), $index * 40, 40);
        if ((not $data)
            or (sha1_hex($$data) ne
                substr(unpack(q[H*], $pieces{refaddr $self}), $index * 40, 40))
            )
        {   vec($bitfield{refaddr $self}, $index, 1) = 0;
            $_client{refaddr $self}->_event(q[piece_hash_fail],
                                    {Session => $self, Index => $index});
            return 0;
        }

        #
        if (vec($bitfield{refaddr $self}, $index, 1) == 0) {   # Only if pass is 'new'
            vec($bitfield{refaddr $self}, $index, 1) = 1;
            $_client{refaddr $self}->_event(q[piece_hash_pass],
                                    {Session => $self, Index => $index});
        }

        #
        return 1;
    }
        sub _as_string {
            my ($self, $advanced) = @_;
            my $dump = q[TODO];
            return print STDERR qq[$dump\n] unless defined wantarray;
            return $dump;
        }

    # Destructor
    DESTROY {
        my ($self) = @_;

        #warn q[Goodbye, ] . $$self;
        delete $_client{refaddr $self};
        delete $path{refaddr $self};
        delete $basedir{refaddr $self};
        delete $size{refaddr $self};
        delete $files{refaddr $self};
        delete $trackers{refaddr $self};
        delete $infohash{refaddr $self};
        delete $_private{refaddr $self};
        delete $pieces{refaddr $self};
        delete $clutter{refaddr $self};
        delete $uploaded{refaddr $self};
        delete $downloaded{refaddr $self};
        delete $_piece_length{refaddr $self};
        delete $nodes{refaddr $self};
        delete $bitfield{refaddr $self};
        delete $working_pieces{refaddr $self};

        #
        return 1;
    }

=pod

=head1 NAME

Net::BitTorrent::Session - Class Representing a Single .torrent File

=head1 Description

=head1 Constructor

=over

=item C<new ( { [ARGS] } )>

Creates a C<Net::BitTorrent::Session> object.  This constructor is
called by
L<Net::BitTorrent::add_session( )|Net::BitTorrent/add_session ( { ... } )>
and should not be used directly.

C<new( )> accepts arguments as a hash, using key-value pairs:

=over

=item C<BaseDir>

The root directory used to store the files related to this session.  This
directory is created if not preexisting.

This is the only optional parameter.

Default: C<./> (Current working directory)

=item C<Client>

The L<Net::BitTorrent|Net::BitTorrent> object this session will
eventually be served from.

=item C<Path>

Filename of the .torrent file to load.

=back

=back

=head1 Methods

=over

=item C<bitfield>

Returns a bitfield representing the pieces that have been successfully
downloaded.

=item C<files>

Returns a list of
L<Net::BitTorrent::Session::File|Net::BitTorrent::Session::File> objects
representing all files contained in the related .torrent file.

=item C<hashcheck>

Verifies the integrity of all L<files|Net::BitTorrent::Session::File>
associated with this session.

This is a blocking method; all processing will stop until this function
returns.

=item C<infohash>

Returns the 20 byte SHA1 hash used to identify this session internally,
with trackers, and with remote peers.

=item C<path>

Returns the L<filename|/Path> of the torrent this object represents.

=item C<size>

Returns the total size of all files listed in the .torrent file.

=item C<trackers>

Returns a list of all
L<Net::BitTorrent::Session::Tracker|Net::BitTorrent::Session::Tracker>
objects related to the session.

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

    1;
}
