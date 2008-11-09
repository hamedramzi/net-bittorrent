#!C:\perl\bin\perl.exe
package Net::BitTorrent::Torrent;
{
    use strict;      # core as of perl 5
    use warnings;    # core as of perl 5.006

    #
    use Digest::SHA qw[sha1_hex];                   # core as of perl 5.009003
    use Carp qw[carp carp];                         # core as of perl 5
    use Cwd qw[cwd];                                # core as of perl 5
    use File::Spec::Functions qw[rel2abs catfile];  # core as of perl 5.00504
    use Scalar::Util qw[blessed weaken refaddr];    # core as of perl 5.007003
    use List::Util qw[sum shuffle max];             # core as of perl 5.007003
    use Fcntl qw[/O_/ /SEEK/ :flock];               # core as of perl 5

    #
    use lib q[../../../lib];
    use Net::BitTorrent::Util qw[:bencode :compact];
    use Net::BitTorrent::Torrent::File;
    use Net::BitTorrent::Torrent::Tracker;
    use Net::BitTorrent::Peer;

    #
    use version qw[qv];                             # core as of 5.009
    our $SVN = q[$Id$];
    our $UNSTABLE_RELEASE = 0; our $VERSION = sprintf(($UNSTABLE_RELEASE ? q[%.3f_%03d] : q[%.3f]), (version->new((qw$Rev$)[1])->numify / 1000), $UNSTABLE_RELEASE);

    #
    # Debugging
    #use Data::Dump qw[pp];
    #
    my %REGISTRY = ();
    my @CONTENTS = \my (
        %_client, %path, %basedir,    # new() params (path is required)
        %size, %files, %trackers, %infohash, %pieces, %uploaded,
        %downloaded, %nodes,  %bitfield, %working_pieces, %_block_length,
        %raw_data,   %status, %error
    );

    # Constructor
    sub new {

        # Creates a new N::B::Torrent object
        # Accepts parameters as key/value pairs in a hash reference
        # Required parameters:
        #  - Path    (.torrent)
        # Optional parameters
        #  - Client  (blessed N::B object)
        #  - BaseDir (root directory for related files; defaults to cwd)
        #  - Status  (initial status of this torrent)
        # Returns
        #    - a new blessed object on success
        #    - undef on failure
        # MO
        # - validate incoming parameters
        # - read .torrent
        # - bdecode data
        # - validate pieces string
        # - get infohash
        # - bless $self
        # - set client
        # - set raw_data
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
        my $self = bless \$class, $class;

        # Param validation... Ugh...
        if (not defined $args) {
            carp q[Net::BitTorrent::Torrent->new({}) requires ]
                . q[a set of parameters];
            return;
        }
        if (ref($args) ne q[HASH]) {
            carp q[Net::BitTorrent::Torrent->new({}) requires ]
                . q[parameters to be passed as a hashref];
            return;
        }
        if (not defined $args->{q[Path]}) {
            carp q[Net::BitTorrent::Torrent->new({}) requires a ]
                . q['Path' parameter];
            return;
        }
        if (not -f $args->{q[Path]}) {
            carp
                sprintf(q[Net::BitTorrent::Torrent->new({}) cannot find '%s'],
                        $args->{q[Path]});
            return;
        }
        if (defined $args->{q[Client]}) {
            if (not blessed $args->{q[Client]}) {
                carp q[Net::BitTorrent::Torrent->new({}) requires a ]
                    . q[blessed 'Client' object];
                return;
            }
            if (not $args->{q[Client]}->isa(q[Net::BitTorrent])) {
                carp q[Net::BitTorrent::Torrent->new({}) requires a ]
                    . q[blessed Net::BitTorrent object in the 'Client' parameter];
                return;
            }
        }
        if (defined $args->{q[BlockLength]}) {    # Undocumented
            if ($args->{q[BlockLength]} !~ m[^\d+$]) {
                carp q[Net::BitTorrent::Torrent->new({}) requires an ]
                    . q[integer 'BlockLength' parameter];
                delete $args->{q[BlockLength]};
            }
        }
        if (defined $args->{q[Status]}) {         # Undocumented
            if ($args->{q[Status]} !~ m[^\d+$]) {
                carp q[Net::BitTorrent::Torrent->new({}) requires an ]
                    . q[integer 'Status' parameter];
                delete $args->{q[Status]};
            }
        }

        # Tidy up some rough edges here
        $args->{q[Path]} = rel2abs($args->{q[Path]});
        $args->{q[BaseDir]} = rel2abs(
                  defined($args->{q[BaseDir]}) ? $args->{q[BaseDir]} : cwd());

        # Here comes the real work...
        my ($TORRENT_FH, $TORRENT_RAW);

        # Open .torrent
        if (not sysopen($TORRENT_FH, $args->{q[Path]}, O_RDONLY)) {
            carp    # difficult to trigger for a test suite
                sprintf(
                 q[Net::BitTorrent::Torrent->new({}) could not open '%s': %s],
                 $args->{q[Path]}, $!);
            return;
        }

    # No need to lock it... right? I mean, what's the worse that could happen?
        flock($TORRENT_FH, LOCK_SH);    # just make an attempt...

        # Read .torrent
        if (sysread($TORRENT_FH, $TORRENT_RAW, -s $args->{q[Path]})
            != -s $args->{q[Path]})
        {   carp    # difficult to trigger for a test suite
                sprintf(
                q[Net::BitTorrent::Torrent->new({}) could not read all %d bytes of '%s' (Read %d instead)],
                -s $args->{q[Path]},
                $args->{q[Path]}, length($TORRENT_RAW)
                );
            return;
        }
        flock($TORRENT_FH, LOCK_UN);    # unlock

        # bdecode data
        $raw_data{refaddr $self} = bdecode($TORRENT_RAW);

        # Keep it clean...
        close($TORRENT_FH);
        undef $TORRENT_FH;
        undef $TORRENT_RAW;

        #
        if (not defined $raw_data{refaddr $self}) {
            carp q[Malformed .torrent];
            return;
        }

        #warn pp $raw_data{refaddr $self}{q[info]}{q[files]};
        #warn $args->{q[Path]};
        # parse pieces string and...
        #   - verify pieces string > 40
        #   - verify pieces string % 40 == 0
        if (length(unpack(q[H*], $raw_data{refaddr $self}{q[info]}{q[pieces]})
            ) < 40
            )
        {    # TODO: Create bad .torrent to trigger this for tests
                #$_client{refaddr $self}
             #    ->_event(q[log], {Level=>ERROR, Msg=>q[Broken torrent: Pieces hash is less than 40 bytes]})
             #  if defined $_client{refaddr $self};
            return;
        }
        if (length(unpack(q[H*], $raw_data{refaddr $self}{q[info]}{q[pieces]})
            ) % 40
            )
        {    # TODO: Create bad .torrent to trigger this for tests
                #$_client{refaddr $self}
             #    ->_event(q[log], {Level=>ERROR, Msg=>q[Broken torrent: Pieces hash will not break apart into even, 40 byte segments]})
             # if defined $_client{refaddr $self};
            return;
        }

        # Store required and extra data
        #
        # What data should I store in its own hash?
        #  - Yes
        #    - infohash
        #    - info/private
        #    - info/piece length
        #    - info/pieces
        #    - announce || announce-list
        #    -
        if (defined $args->{q[Client]}) {
            $_client{refaddr $self} = $args->{q[Client]};
            weaken $_client{refaddr $self};
        }
        $infohash{refaddr $self}
            = sha1_hex(bencode($raw_data{refaddr $self}{q[info]}));
        $path{refaddr $self}           = $args->{q[Path]};
        $basedir{refaddr $self}        = $args->{q[BaseDir]};
        $working_pieces{refaddr $self} = {};
        $_block_length{refaddr $self} = (defined $args->{q[BlockLength]}
                                         ? $args->{q[BlockLength]}
                                         : (2**14)
        );
        $nodes{refaddr $self} = q[];
        ${$bitfield{refaddr $self}}
            = pack(q[b*], qq[\0] x $self->_piece_count);

        # don't let them do silly stuff...
        if (defined $args->{q[Status]}) {
            $args->{q[Status]} ^= 64  if $args->{q[Status]} & 64;
            $args->{q[Status]} ^= 128 if $args->{q[Status]} & 128;
        }
        ${$status{refaddr $self}} |= (
              defined $args->{q[Status]}      ? $args->{q[Status]}
            : defined $_client{refaddr $self} ? 1
            : 0    # started (default)
        );
        ${$status{refaddr $self}} |= 64;    # loaded
        ${$status{refaddr $self}} |= 128
            if defined $_client{refaddr $self};    # queued
        ${$error{refaddr $self}} = undef;

       #q[nodes]     => $raw_data{refaddr $self}{q[nodes]},  # DHT
       #q[sources]   => $raw_data{refaddr $self}{q[sources]},    # Depthstrike
       #q[url-list]  => $raw_data{refaddr $self}{q[url-list]},   # GetRight
       #q[httpseeds] => $raw_data{refaddr $self}{q[httpseeds]},  # BitTornado
       #
       #q[name] => $raw_data{refaddr $self}{q[info]}{q[name]}
       #warn pp \%raw_data;
       # Files
        my @_files;
        if (defined $raw_data{refaddr $self}{q[info]}{q[files]})
        {    # multifile .torrent
            for my $file (@{$raw_data{refaddr $self}{q[info]}{q[files]}}) {
                push @_files, [
                    catfile(
                        $basedir{refaddr $self},
                        ( #defined($raw_data{refaddr $self}{q[info]}{q[name.utf-8]})
                            #? $raw_data{refaddr $self}{q[info]}{q[name.utf-8]}
                            #:
                           $raw_data{refaddr $self}{q[info]}{q[name]}
                        ),
                        @{  (    #defined($file->{q[path.utf-8]})
                                 #? $file->{q[path.utf-8]}
                                 #:
                             $file->{q[path]}
                            )
                            }
                    ),
                    $file->{q[length]}
                ];
            }
        }
        else {
            push @_files, [
                catfile(
                    $basedir{refaddr $self},
                    ( #defined($raw_data{refaddr $self}{q[info]}{q[name.utf-8]})
                           #? $raw_data{refaddr $self}{q[info]}{q[name.utf-8]}
                           #:
                       $raw_data{refaddr $self}{q[info]}{q[name]}
                    )
                ),
                $raw_data{refaddr $self}{q[info]}{q[length]}
            ];
        }
        $size{refaddr $self} = 0;
        for my $_file (@_files) {
            my ($path, $size) = @$_file;
            {              # XXX - an attempt to make paths safe. Needs work.
                $path =~ s[\.\.][]g;
                $path =~ m[(.+)];      # Mark it as untainted
                $path = $1;
            }
            if (    defined $raw_data{refaddr $self}{q[encoding]}
                and $raw_data{refaddr $self}{q[encoding]} !~ m[^utf-?8$]i
                and not utf8::is_utf8($path)
                and require Encode)
            {    # some clients do a poor/incomplete job with encoding so we
                    # work around it by upgrading and setting the utf8 flag
                $path =
                    Encode::decode(Encode::find_encoding(
                                         $raw_data{refaddr $self}{q[encoding]}
                                       )->name,
                                   $path
                    );
            }
            push(@{$files{refaddr $self}},
                 Net::BitTorrent::Torrent::File->new(
                                 {Size    => $size,
                                  Path    => $path,
                                  Torrent => $self,
                                  Index   => scalar(@{$files{refaddr $self}})
                                 }
                 )
            );
            $size{refaddr $self} += $size;
        }

        # Trackers
        if (defined $raw_data{refaddr $self}{q[announce-list]})
        {    # Multitracker
            for my $tier (@{$raw_data{refaddr $self}{q[announce-list]}}) {
                push(@{$trackers{refaddr $self}},
                     Net::BitTorrent::Torrent::Tracker->new(
                                             {Torrent => $self, URLs => $tier}
                     )
                );
            }
        }
        elsif (defined $raw_data{refaddr $self}{q[announce]})
        {    # Single tracker
            push(@{$trackers{refaddr $self}},
                 Net::BitTorrent::Torrent::Tracker->new(
                           {Torrent => $self,
                            URLs    => [$raw_data{refaddr $self}{q[announce]}]
                           }
                 )
            );
        }
        else {    # No trackers; requires DHT
            $trackers{refaddr $self} = [];
            if ($self->private) {    # I'm not sure how to handle this.  We...
                 # could resort to Webseeding but... why would anyone do this?
                carp q[This torrent does not contain any trackers and does ]
                    . q[not allow DHT];
                return;
            }
        }

        # threads stuff
        weaken($REGISTRY{refaddr $self} = $self);
        if ($threads::shared::threads_shared)
        {        # allows non-blocking hashcheck
            threads::shared::share($bitfield{refaddr $self});
            threads::shared::share($status{refaddr $self});
            threads::shared::share($error{refaddr $self});
        }

        # Set scalar content for blessed $self
        $$self = $infohash{refaddr $self};
        $self->start if ${$status{refaddr $self}} & 1;

        #
        return $self;
    }

    # Accessors | Public
    sub infohash   { return $infohash{refaddr +shift}; }
    sub trackers   { return $trackers{refaddr +shift}; }
    sub bitfield   { return ${$bitfield{refaddr +shift}}; }
    sub path       { return $path{refaddr +shift}; }
    sub files      { return $files{refaddr +shift}; }
    sub size       { return $size{refaddr +shift}; }
    sub status     { return ${$status{refaddr +shift}}; }
    sub downloaded { return $downloaded{refaddr +shift} || 0; }
    sub uploaded   { return $uploaded{refaddr +shift} || 0; }
    sub error      { return ${$error{refaddr +shift}}; }

    # From metadata
    sub comment       { return $raw_data{refaddr +shift}{q[comment]}; }
    sub created_by    { return $raw_data{refaddr +shift}{q[created by]}; }
    sub creation_date { return $raw_data{refaddr +shift}{q[creation date]}; }
    sub name          { return $raw_data{refaddr +shift}{q[info]}{q[name]}; }

    sub private {
        return $raw_data{refaddr +shift}{q[info]}{q[private]} ? 1 : 0;
    }    # XXX - needed?
    sub raw_data { return $raw_data{refaddr +shift} }

    sub is_complete {
        my ($self) = @_;
        return if ${$status{refaddr $self}} & 2;    # hashchecking
        return ((substr(unpack(q[b*], $self->_wanted), 0, $self->_piece_count)
                     !~ 1
                )
                ? 1
                : 0
        );
    }

    # Mutators | Private
    sub _set_bitfield {
        my ($self, $new_value) = @_;
        return if ${$status{refaddr $self}} & 2;    # hashchecking
        return if length ${$bitfield{refaddr $self}} != length $new_value;

        # XXX - make sure bitfield conforms to what we expect it to be
        return ${$bitfield{refaddr $self}} = $new_value;
    }

    sub _set_status {
        my ($self, $new_value) = @_;
        return if ${$status{refaddr $self}} & 2;    # hashchecking
             # XXX - make sure status conforms to what we expect it to be
        return ${$status{refaddr $self}} = $new_value;
    }

    sub _set_error {
        my ($self, $msg) = @_;
        ${$error{refaddr $self}} = $msg;
        $self->stop();
        ${$status{refaddr $self}} &= 16;
        return 1;
    }

    # Accessors | Private
    sub _client       { return $_client{refaddr +shift}; }
    sub _block_length { return $_block_length{refaddr +shift} }

    sub _piece_count {    # XXX - could use a cache...
        my ($self) = @_;
        return
            int(
               length(
                   unpack(q[H*], $raw_data{refaddr $self}{q[info]}{q[pieces]})
                   ) / 40
            );
    }
    sub _compact_nodes { return $nodes{refaddr +shift}; }

    sub _wanted {
        my ($self) = @_;
        return if ${$status{refaddr $self}} & 2;    # hashchecking
             #if (${$status{refaddr $self}} & 16) {
             #    carp q[Torrent has been stopped due to error];
             #    return;
             #}
        my $wanted = q[0] x $self->_piece_count;
        my $p_size = $raw_data{refaddr $self}{q[info]}{q[piece length]};
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
        return (
             pack(q[b*], $wanted)
                 | ${$bitfield{refaddr $self}} ^ ${$bitfield{refaddr $self}});
    }

    # Methods | Public
    sub hashcheck {
        my ($self) = @_;
        return if ${$status{refaddr $self}} & 32;

        #if (${$status{refaddr $self}} & 16) {
        #    carp q[Torrent has been stopped due to error];
        #    return;
        #}
        my $start_after_check = (((${$status{refaddr $self}} & 128)
                                      && ${$status{refaddr $self}} & 4
                                 )
                                     || ${$status{refaddr $self}} & 1
        );
        ${$status{refaddr $self}} |= 2
            if !${$status{refaddr $self}} & 2;    # hashchecking
        $self->stop();
        for my $index (0 .. ($self->_piece_count - 1)) {
            $self->_check_piece_by_index($index);
        }
        ${$status{refaddr $self}} ^= 4
            if ${$status{refaddr $self}} & 4;     # start after check
        ${$status{refaddr $self}} ^= 8
            if !(${$status{refaddr $self}} & 8);    # checked
        ${$status{refaddr $self}} ^= 2
            if ${$status{refaddr $self}} & 2;       # not hashchecking
        if ($start_after_check) { $self->start(); }
        return 1;
    }

    sub pause {                                     # untested
        my ($self) = @_;

        #if (${$status{refaddr $self}} & 16) {
        #    carp q[Torrent has been stopped due to error];
        #    return;
        #}
        if (!${$status{refaddr $self}} & 128) {
            carp q[Cannot pause an orphan torrent];
            return;
        }
        if (!${$status{refaddr $self}} & 1) {
            carp q[Cannot pause a stopped torrent];
            return;
        }
        return ${$status{refaddr $self}} |= 32;
    }

    sub start {    # untested
        my ($self) = @_;
        warn ${$status{refaddr $self}};
        if (!${$status{refaddr $self}} & 128) {
            carp q[Cannot start an orphan torrent];
            return;
        }
        ${$status{refaddr $self}} ^= 16
            if ${$status{refaddr $self}} & 16;    # clear error status
        ${$status{refaddr $self}} ^= 32
            if ${$status{refaddr $self}} & 32;    # clear paused status
        ${$status{refaddr $self}} |= 1
            if !(${$status{refaddr $self}} & 1);
        $_client{refaddr $self}->_schedule(
                                  {Time   => time + 15,
                                   Code   => sub { shift->_new_peer if @_; },
                                   Object => $self
                                  }
        ) if defined $_client{refaddr $self};
        return ${$status{refaddr $self}};
    }

    sub stop {                                    # untested
        my ($self) = @_;
        if (!${$status{refaddr $self}} & 128) {
            carp q[Cannot stop an orphan torrent];
            return;
        }

        # close peers
        for my $_peer ($self->_peers) {
            $_peer->_disconnect(q[Torrent has been stopped]);
        }

        # close filehandles
        for my $_file (@{$files{refaddr $self}}) { $_file->_close(); }

        #
        ${$status{refaddr $self}} ^= 1
            if (${$status{refaddr $self}} & 1);
        return !!${$status{refaddr $self}} & 1;
    }

    sub queue {    # untested
        my ($self, $client) = @_;
        if ($client) {
            if (not blessed $client) {
                carp q[Net::BitTorrent::Torrent->queue() requires a ]
                    . q[blessed client object];
                return;
            }
            if (not $client->isa(q[Net::BitTorrent])) {
                carp q[Net::BitTorrent::Torrent->queue() requires a ]
                    . q[blessed Net::BitTorrent object];
                return;
            }
        }
        else {
            carp q[Net::BitTorrent::Torrent->queue() requires a ]
                . q[blessed Net::BitTorrent object];
            return;
        }
        if ($_client{refaddr $self} or ${$status{refaddr $self}} & 128) {
            carp q[Cannot serve the same .torrent more than once];
            return;
        }
        $_client{refaddr $self} = $client;
        weaken $_client{refaddr $self};

        #
        ${$status{refaddr $self}} ^= 128;
        return $_client{refaddr $self};
    }

    # Methods | Private
    sub _add_uploaded {
        my ($self, $amount) = @_;
        if (!${$status{refaddr $self}} & 128) { return; }

        #if (${$status{refaddr $self}} & 16) {
        #    carp q[Torrent has been stopped due to error];
        #    return;
        #}
        return if not defined $_client{refaddr $self};
        return if ${$status{refaddr $self}} & 2;         # hashchecking
        $uploaded{refaddr $self} += (($amount =~ m[^\d+$]) ? $amount : 0);
    }

    sub _add_downloaded {
        my ($self, $amount) = @_;
        if (!${$status{refaddr $self}} & 128) { return; }

        #if (${$status{refaddr $self}} & 16) {
        #     carp q[Torrent has been stopped due to error];
        #     return;
        # }
        return if not defined $_client{refaddr $self};
        return if ${$status{refaddr $self}} & 2;         # hashchecking
        $downloaded{refaddr $self} += (($amount =~ m[^\d+$]) ? $amount : 0);
    }

    sub _append_compact_nodes {                          # XXX - untested
        my ($self, $nodes) = @_;
        if (!${$status{refaddr $self}} & 128) { return; }

        #if (${$status{refaddr $self}} & 16) {
        #    carp q[Torrent has been stopped due to error];
        #    return;
        #}
        return if not defined $_client{refaddr $self};
        if (not $nodes) { return; }
        $nodes{refaddr $self} ||= q[];
        return $nodes{refaddr $self}
            = compact(uncompact($nodes{refaddr $self} . $nodes));
    }

    sub _new_peer {
        my ($self) = @_;
        return if not defined $_client{refaddr $self};
        return if ${$status{refaddr $self}} & 2;         # hashchecking
        return if !${$status{refaddr $self}} & 1;        # not started
             #if (${$status{refaddr $self}} & 16) {
             #    carp q[Torrent has been stopped due to error];
             #    return;
             #}

        #
        $_client{refaddr $self}->_schedule(
                                         {Time   => time + 15,
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
        if ($self->is_complete)        { return; }
        if (not $nodes{refaddr $self}) { return; }

        #
        my @nodes = uncompact($nodes{refaddr $self});

        #
        for (1 .. (30 - scalar $self->_peers)) {
            last if not @nodes;

            #
            my $node = shift @nodes;

            #
            my $ok = $_client{refaddr $self}
                ->_event(q[ip_filter], {Address => $node});
            if (defined $ok and $ok == 0) { next; }

            #
            my $peer =
                Net::BitTorrent::Peer->new({Address => $node,
                                            Torrent => $self
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
        return if not defined $_client{refaddr $self};
        return if !${$status{refaddr $self}} & 128;      # orphan

        #
        my $_connections = $_client{refaddr $self}->_connections;
        return map {
            (    ($_->{q[Object]}->isa(q[Net::BitTorrent::Peer]))
             and ($_->{q[Object]}->_torrent)
             and ($_->{q[Object]}->_torrent eq $self))
                ? $_->{q[Object]}
                : ()
        } values %$_connections;
    }

    sub _add_tracker {
        my ($self, $tier) = @_;
        return if not defined $_client{refaddr $self};
        return if !${$status{refaddr $self}} & 128;
        carp q[Please, pass new tier in an array ref...]
            unless ref $tier eq q[ARRAY];
        return
            push(@{$trackers{refaddr $self}},
                 Net::BitTorrent::Torrent::Tracker->new(
                                             {Torrent => $self, URLs => $tier}
                 )
            );
    }

    sub _piece_by_index {
        my ($self, $index) = @_;
        return if !${$status{refaddr $self}} & 1;

        #if (${$status{refaddr $self}} & 16) {
        #    carp q[Torrent has been stopped due to error];
        #    return;
        #}
        #
        if (not defined $index) {
            carp
                q[Net::BitTorrent::Torrent->_piece_by_index() requires an index];
            return;
        }

        #
        if ($index !~ m[^\d+$]) {
            carp
                q[Net::BitTorrent::Torrent->_piece_by_index() requires a positive integer];
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
        if (not defined $_client{refaddr $self}) {
            carp
                q[Net::BitTorrent::Torrent->_pick_piece(PEER) will not on an orphan torrent];
            return;
        }
        if (!${$status{refaddr $self}} & 1) {
            carp
                q[Net::BitTorrent::Torrent->_pick_piece(PEER) will not work while hashchecking];
            return;
        }

        #if (${$status{refaddr $self}} & 16) {
        #    carp q[Torrent has been stopped due to error];
        #    return;
        #}
        if (${$status{refaddr $self}} & 2) {
            carp
                q[Net::BitTorrent::Torrent->_pick_piece(PEER) will not work while hashchecking];
            return;
        }
        if (not defined $peer) {
            carp
                q[Net::BitTorrent::Torrent->_pick_piece(PEER) requires a peer];
            return;
        }
        if (not blessed $peer) {
            carp
                q[Net::BitTorrent::Torrent->_pick_piece(PEER) requires a blessed peer];
            return;
        }
        if (not $peer->isa(q[Net::BitTorrent::Peer])) {
            carp
                q[Net::BitTorrent::Torrent->_pick_piece(PEER) requires a peer object];
            return;
        }

        #
        #use Data::Dump qw[pp];
        #warn q[_pick_piece ] . pp $working_pieces{refaddr $self};
        #
        my $piece;

        # pieces this peer has vs pieces we need
        my $_wanted   = $self->_wanted;
        my $relevence = $peer->_bitfield & $_wanted;

        #
        return if unpack(q[b*], $relevence) !~ m[1];

        #
        my $endgame = (    # XXX - make this a smarter ratio
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
        my $slots = int(
               ((2**23) / $raw_data{refaddr $self}{q[info]}{q[piece length]}))
            ;    # ~8M/peer
        my $unchoked_peers
            = scalar(grep { $_->_peer_choking == 0 } $self->_peers);
        my $blocks_per_piece = int(
              $raw_data{refaddr $self}{q[info]}{q[piece length]} / (
                  ($raw_data{refaddr $self}{q[info]}{q[piece length]} < 2**14)
                  ? $raw_data{refaddr $self}{q[info]}{q[piece length]}
                  : 2**14
              )
        );
        my $max_working_pieces
            = max(8, int(($slots * $unchoked_peers) / $blocks_per_piece) + 1);

        #warn sprintf q[$max_working_pieces: %d], $max_working_pieces;
        #
        if (scalar(grep { $_->{q[Slow]} == 0 }
                       values %{$working_pieces{refaddr $self}}
            ) >= $max_working_pieces
            )
        {    #warn sprintf q[%d>=%d],
                #    (scalar(keys %{$working_pieces{refaddr $self}})),
                #    $max_working_pieces;
            my @indexes
                = grep { $working_pieces{refaddr $self}{$_}{q[Slow]} == 0 }
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
            my %weights;
            for my $i (0 .. ($self->_piece_count - 1))
            {    # XXX - Far from efficient...
                if (vec($relevence, $i, 1)) {
                    $weights{$i} = 1;
                }
            }
            return if not keys %weights;

            # [id://230661]
            my $total    = sum values %weights;
            my $rand_val = $total * rand;
            my $index;
            for my $i (reverse sort keys %weights) {
                $rand_val -= $weights{$i};
                if ($rand_val <= 0) { $index = $i; last; }
            }
            return if not defined $index;
            my $_piece_length = (    # XXX - save some time and store this?
                ($index == int(
                            $size{refaddr $self}
                          / $raw_data{refaddr $self}{q[info]}{q[piece length]}
                 )
                )
                ? ($size{refaddr $self} % $raw_data{refaddr $self}{q[info]}
                   {q[piece length]})
                : ($raw_data{refaddr $self}{q[info]}{q[piece length]})
            );

            #
            my $block_length = (
                        ($raw_data{refaddr $self}{q[info]}{q[piece length]}
                             < $_block_length{refaddr $self}
                        )
                        ? ($raw_data{refaddr $self}{q[info]}{q[piece length]})
                        : $_block_length{refaddr $self}
            );
            my $block_length_last
                = ($raw_data{refaddr $self}{q[info]}{q[piece length]}
                   % $_piece_length);

            #die $block_length_last;
            # XXX - may not be balanced
            my $block_count
                = (int($_piece_length / $block_length)
                       + ($block_length_last ? 1 : 0));

            #
            $piece = {Index             => $index,
                      Priority          => $weights{$index},
                      Blocks_Requested  => [map { {} } 1 .. $block_count],
                      Blocks_Recieved   => [map {0} 1 .. $block_count],
                      Block_Length      => $block_length,
                      Block_Length_Last => $block_length_last,
                      Block_Count       => $block_count,
                      Length            => $_piece_length,
                      Endgame           => $endgame,
                      Slow              => 0,
                      Touch             => 0
            };
        }

        #
        if ($piece) {
            if (not
                defined $working_pieces{refaddr $self}{$piece->{q[Index]}})
            {   $working_pieces{refaddr $self}{$piece->{q[Index]}} = $piece;
            }
        }

        #
        return $piece
            ? $working_pieces{refaddr $self}{$piece->{q[Index]}}
            : ();
    }

    sub _write_data {
        my ($self, $index, $offset, $data) = @_;
        return if not defined $_client{refaddr $self};
        return if ${$status{refaddr $self}} & 2;         # hashchecking
        return if !${$status{refaddr $self}} & 1;        # not started
             #if (${$status{refaddr $self}} & 16) {
             #    carp q[Torrent has been stopped due to error];
             #    return;
             #}

        # TODO: param validation
        if ((length($$data) + (
                 ($raw_data{refaddr $self}{q[info]}{q[piece length]} * $index)
                 + $offset
             )
            ) > $size{refaddr $self}
            )
        {   carp q[Too much data or bad offset data for this torrent];
            return;
        }

        #
        my $file_index = 0;
        my $total_offset
            = int(
               (($index * $raw_data{refaddr $self}{q[info]}{q[piece length]}))
               + ($offset || 0));

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
        if (($length + (
                 ($raw_data{refaddr $self}{q[info]}{q[piece length]} * $index)
                 + $offset
             )
            ) > $size{refaddr $self}
            )
        {   carp q[Too much or bad offset data for this torrent];
            return;
        }

        #
        my $file_index = 0;
        my $total_offset
            = int(
               (($index * $raw_data{refaddr $self}{q[info]}{q[piece length]}))
               + ($offset || 0));

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
            my $_data
                = $files{refaddr $self}->[$file_index]->_read($this_read);
            $data .= $_data if $_data;

            #
            $file_index++;
            $length -= $this_read;
            last READ if not defined $files{refaddr $self}->[$file_index];
            $total_offset = 0;
        }

        #
        return \$data;
    }

    sub _check_piece_by_index {
        my ($self, $index) = @_;

        #
        if (not defined $index) {
            carp q[Net::BitTorrent::Torrent->_check_piece_by_index( INDEX ) ]
                . q[requires an index.];
            return;
        }
        if ($index !~ m[^\d+$]) {
            carp q[Net::BitTorrent::Torrent->_check_piece_by_index( INDEX ) ]
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
        my $data = $self->_read_data(
                  $index, 0,
                  ($index == ($self->_piece_count - 1)
                   ? ($size{refaddr $self} % $raw_data{refaddr $self}{q[info]}
                      {q[piece length]})
                   : $raw_data{refaddr $self}{q[info]}{q[piece length]}
                  )
        );

#
#warn sprintf q[%s vs %s],
#     sha1_hex($data),
#     substr(unpack(q[H*], $raw_data{refaddr $self}{q[info]}{q[pieces]}), $index * 40, 40);
        if ((not $data)
            or (sha1_hex($$data) ne substr(
                              unpack(
                                  q[H*],
                                  $raw_data{refaddr $self}{q[info]}{q[pieces]}
                              ),
                              $index * 40,
                              40
                )
            )
            )
        {   vec(${$bitfield{refaddr $self}}, $index, 1) = 0;
            $_client{refaddr $self}->_event(q[piece_hash_fail],
                                          {Torrent => $self, Index => $index})
                if defined $_client{refaddr $self};
            return 0;
        }

        #
        if (vec(${$bitfield{refaddr $self}}, $index, 1) == 0)
        {    # Only if pass is 'new'
            vec(${$bitfield{refaddr $self}}, $index, 1) = 1;
            $_client{refaddr $self}->_event(q[piece_hash_pass],
                                          {Torrent => $self, Index => $index})
                if defined $_client{refaddr $self};
        }

        #
        return 1;
    }

    sub _as_string {
        my ($self, $advanced) = @_;
        my $dump
            = !$advanced
            ? $self->infohash
            : sprintf <<'END',
Torrent: %s
 Path:       %s
 Storage:    %s
 Infohash:   %s
 Size:       %d bytes
 Status:     %d
 --
 Num Pieces: %d
 Piece Size: %d bytes
 Working:    %s
 --
 Files:      %s
 --
 Trackers:   %s
 --
 DHT:        %s

q[TODO]
END
            $raw_data{refaddr $self}{q[info]}{q[name]},
            $self->path(),
            $basedir{refaddr $self},
            $self->infohash(),
            $self->size(),
            $self->status(),
            $self->_piece_count(),
            $raw_data{refaddr $self}{q[info]}{q[piece length]},
            join(q[, ], (keys %{$working_pieces{refaddr $self}}) || q[N/A]),

            # Files
            (map { qq[\n\t] . $_->_as_string($advanced) }
             @{$files{refaddr $self}}),

            # Trackers
            (map { qq[\n\t] . $_->_as_string($advanced) }
             @{$trackers{refaddr $self}}),

            # DHT
            ($self->private
             ? q[[Private - DHT/Peer EXchange disabled]]
             : q[]
            );
        return print STDERR qq[$dump\n] unless wantarray;
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
            weaken $_client{$_nID};

            #  update he weak refernce to the new, cloned object
            weaken($REGISTRY{$_nID} = $_obj);
            delete $REGISTRY{$_oID};
        }
        return 1;
    }

    # Destructor
    DESTROY {
        my ($self) = @_;
        for (@CONTENTS) {
            delete $_->{refaddr $self};
        }

        #warn q[Goodbye, ] . $$self;
        delete $REGISTRY{refaddr $self};

        #
        return 1;
    }
    1;
}

=pod

=head1 NAME

Net::BitTorrent::Torrent - Class Representing a Single .torrent File

=head1 Description

C<Net::BitTorrent::Torrent> objects are typically created by the
C<Net::BitTorrent> class.

Standalone C<Net::BitTorrent::Torrent> objects can be made for
informational use.  See <new|/"new ( { [ARGS] } )"> and
L<queue|/"queue ( CLIENT )">.

=head1 Constructor

=over

=item C<new ( { [ARGS] } )>

Creates a C<Net::BitTorrent::Torrent> object.  This constructor is
called by
L<Net::BitTorrent::add_torrent( )|Net::BitTorrent/add_torrent ( { ... } )>.

C<new( )> accepts arguments as a hash, using key-value pairs:

=over

=item C<BaseDir>

The root directory used to store the files related to this torrent.  This
directory is created if not preexisting.

This is an optional parameter.

Default: C<./> (Current working directory)

=item C<Client>

The L<Net::BitTorrent|Net::BitTorrent> object this torrent will
eventually be served from.

This is an optional parameter.

No default.  Without a defined parent client, his object is very limited
in capability.  Basic informaion and <hash checking|/hashcheck> only.
Orphan objects are obviously not L<queued|/"status ( )"> automatically
and must be added to a client <manually|/"queue ( CLIENT )">.

=item C<Path>

Filename of the .torrent file to load.

This is the only required parameter.

=item C<Status>

Initial status of the torrent.  This parameter is ORed with the loaded
and queued (if applicable) values.

For example, you could set the torrent to automatically start after
L<hashcheck|/"hashcheck ( )"> with C<{ [...] Status =E<gt> 4, [...] }>.

This is an optional parameter.

Default: 1 (started)

See also: L<status|/"status ( )">

Note: This is alpha code and may not work correctly.

=back

=back

=head1 Methods

=over

=item C<bitfield ( )>

Returns a bitfield representing the pieces that have been successfully
downloaded.

=item C<comment ( )>

Returns the (optional) comment the original creator included in the
.torrent metadata.

=item C<created_by ( )>

Returns the (optional) "created by" string included in the .torrent
metadata. This is usually a software version.

=item C<creation_date ( )>

Returns the (optional) creation time of the torrent, in standard UNIX
epoch format.

=item C<downloaded ( )>

Returns the total amount downloaded from remote peers since the client
started transfering data related to this .torrent.

See also: L<uploaded |/"uploaded ( )">

=item C<error ( )>

Returns the most recent error that caused the software to set the
error L<status|/"status ( )">.  Torrents with active errors are
automatically stopped and must be L<started|/"start ( )">.

See also: L<status|/"status ( )">, L<start|/"start ( )">

=item C<files ( )>

Returns a list of
L<Net::BitTorrent::Torrent::File|Net::BitTorrent::Torrent::File> objects
representing all files contained in the related .torrent file.

=item C<hashcheck ( )>

Verifies the integrity of all L<files|Net::BitTorrent::Torrent::File>
associated with this torrent.

This is a blocking method; all processing will stop until this function
returns.

See also: L<bitfield|/"bitfield ( )">, L<status|/"status ( )">

=item C<infohash ( )>

Returns the 20 byte SHA1 hash used to identify this torrent internally,
with trackers, and with remote peers.

=item C<is_complete ( )>

Returns a bool value based on download progress.  Returns C<true> when we
have completed every L<file|Net::BitTorrent::Torrent::File> with a
priority above C<0>.  Otherwise, returns C<false>.

See also:
L<Net::BitTorrent::Torrent::File-E<gt>priority()|Net::BitTorrent::Torrent::File/"priority( )">

=item C<name ( )>

Returns the advisory name used when creating the related files on disk.

In a single file torrent, this is used as the filename by default.  In a
multiple file torrent, this is used as the containing directory for
related files.

=item C<path ( )>

Returns the L<filename|/Path> of the torrent this object represents.

=item C<private ( )>

Returns bool value dependant on whether the private flag is set in the
.torrent metadata.  Private torrents disallow information sharing via DHT
and PEX.

=item C<queue ( CLIENT )>

Adds a standalone (or orphan) torrent object to the particular
L<CLIENT|Net::BitTorrent> object's queue.

See also:
L<remove_torrent ( )|/"Net::BitTorrent::remove_torrent ( TORRENT )">

=item C<raw_data ( )>

Returns the bdecoded metadata. found in the .torrent file.

=item C<size ( )>

Returns the total size of all files listed in the .torrent file.

=item C<status ( )>

Returns the internal status of this C<Net::BitTorrent::Torrent> object.
States are bitwise C<AND> valuses of...

=begin html

 <table summary="List of possible states">
      <thead>
        <tr>
          <td>
            Value
          </td>
          <td>
            Type
          </td>
          <td>
            Notes
          </td>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>
            1
          </td>
          <td>
            Started
          </td>
          <td>
            New peers are accepted and pieces are activly being
            transfered
          </td>
        </tr>
        <tr>
          <td>
            2
          </td>
          <td>
            Checking
          </td>
          <td>
            Currently hashchecking (possibly in another thread)
          </td>
        </tr>
        <tr>
          <td>
            4
          </td>
          <td>
            Start after check
          </td>
          <td>
            Unused in this version
          </td>
        </tr>
        <tr>
          <td>
            8
          </td>
          <td>
            Checked
          </td>
          <td>
            Files of this torrent have been checked
          </td>
        </tr>
        <tr>
          <td>
            16
          </td>
          <td>
            Error
          </td>
          <td>
            Activity is halted and may require user intervention
            (Unused in this version)
          </td>
        </tr>
        <tr>
          <td>
            32
          </td>
          <td>
            Paused
          </td>
          <td>
            New peers are accepted but no piece date is transfered or
            asked for
          </td>
        </tr>
        <tr>
          <td>
            64
          </td>
          <td>
            Loaded
          </td>
          <td>
            Torrent has been parsed without error
          </td>
        </tr>
        <tr>
          <td>
            128
          </td>
          <td>
            Queued
          </td>
          <td>
            Has an associated Net::BitTorrent parent
          </td>
        </tr>
      </tbody>
    </table>

=end html

=begin :text,wiki

   1 = Started  (New peers are accepted, etc.)
   2 = Checking (Currently hashchecking)
   4 = Start after Check*
   8 = Checked
  16 = Error*   (Activity is halted and may require user intervention)
  32 = Paused
  64 = Loaded
 128 = Queued   (Has an associated Net::BitTorrent parent)

 * Currently unused

=end :text,wiki

For example, a status of C<201> implies the torrent is queued (C<128>),
loaded (C<64>), hash checked (C<8>), and is currently active (C<1>).
This scheme is inspired by µTorrent.

When torrents have the a status that indicates an error, they must be
L<restarted|/start ( )>.  The reason for the error may be returned by
L<error|/"error ( )">.

Note: States are alpha and may not work as advertised.  Yet.

=item C<start ( )>

Starts a paused or stopped torrent.

See also: L<status|/"status ( )">, L<stop|/"stop ( )">,
L<pause|/"pause ( )">

=item C<stop ( )>

Stops an active or paused torrent.  All related sockets (peers) are
disconnected and all files are closed.

See also: L<status|/"status ( )">, L<start|/"start ( )">,
L<pause|/"pause ( )">

=item C<pause ( )>

Pauses an active torrent without closing related sockets.

See also: L<status|/"status ( )">, L<stop|/"stop ( )">,
L<start|/"start ( )">

=item C<trackers>

Returns a list of all
L<Net::BitTorrent::Torrent::Tracker|Net::BitTorrent::Torrent::Tracker>
objects related to the torrent.

=item C<uploaded ( )>

Returns the total amount uploaded to remote peers since the client
started transfering data related to this .torrent.

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
