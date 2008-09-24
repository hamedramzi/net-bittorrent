#!/usr/bin/perl -w
use strict;
use warnings;

#
use lib q[../../lib];
use lib q[./t/lib];
$|++;

# let's keep track of where we are...
my $test_builder = Test::More->builder;

#
my $simple_dot_torrent = q[./t/900_data/950_torrents/953_miniswarm.torrent];

# Make sure the path is correct
chdir q[../../] if not -f $simple_dot_torrent;

#
BEGIN {
    use Test::More;
    plan tests => 79;
$SIG{__WARN__} = sub {}; # Quiet Carp
    # Ours
    use_ok(q[File::Temp],   qw[tempdir]);
    use_ok(q[Scalar::Util], qw[/weak/]);
    use_ok(q[Socket],       qw[/pack_sockaddr_in/ /inet_/]);

    # Mine
    use_ok(q[Net::BitTorrent]);
}
my ($tempdir) = tempdir(q[~NBSF_test_XXXXXXXX], CLEANUP => 1, TMPDIR => 1);
diag(sprintf(q[File::Temp created '%s' for us to play with], $tempdir));
my $client = Net::BitTorrent->new({LocalHost => q[127.0.0.1]});
if (!$client) {
    diag(sprintf q[Socket error: [%d] %s], $!, $!);
    skip(($test_builder->{q[Expected_Tests]} - $test_builder->{q[Curr_Test]}),
         q[Failed to create client]
    );
}
my $session;

END {
    return if not defined $session;
    for my $file (@{$session->files}) { $file->_close() }
}

#
diag(q[TODO: Install event handlers]);

#
diag(q[Testing (private) Net::BitTorrent::__build_reserved()]);
is(Net::BitTorrent::__build_reserved(), qq[\0\0\0\0\0\20\0\0],
    q[Net::BitTorrent::__build_reserved() currently only indicates that we support the ExtProtocol]
);

#
diag(q[Testing (private) Net::BitTorrent::__socket_open()]);
is(Net::BitTorrent::__socket_open(),
    undef, q[__socket_open() returns undef]);
is(Net::BitTorrent::__socket_open(2200),
    undef, q[__socket_open(2200) returns undef]);
is(Net::BitTorrent::__socket_open(undef, 3400),
    undef, q[__socket_open(undef, 3400) returns undef]);
is(Net::BitTorrent::__socket_open(undef, undef),
    undef, q[__socket_open(undef, undef) returns undef]);
is( Net::BitTorrent::__socket_open(inet_aton(q[127.0.0.1]), q[test]),
    undef,
    q[__socket_open(inet_aton(q[127.0.0.1]), q[test]) returns undef]
);
is(Net::BitTorrent::__socket_open({}),
    undef, q[__socket_open({}) returns undef]);
is(Net::BitTorrent::__socket_open(q[127.0.0.1:5500]),
    undef,
    q[__socket_open(q[127.0.0.1:5500]) returns undef]);

#
my $socket_one = Net::BitTorrent::__socket_open(q[127.0.0.1], 5500);
isa_ok(
     $socket_one,
     q[GLOB],
     q[__socket_open(q[127.0.0.1], 5500) returns a socket...]
);
my ($port_one, $packed_ip_one) = unpack_sockaddr_in(getsockname($socket_one));
is($port_one, 5500, q[   ...which would accept connections on port 5500...]);
is($packed_ip_one, inet_aton(q[127.0.0.1]),
    q[   ...if it were open to the outside world.]);

#
my $socket_two = Net::BitTorrent::__socket_open(q[127.0.0.1], 5500);
is($socket_two, undef,
    q[Retrying Net::BitTorrent::__socket_open(q[127.0.0.1], 5500) returns undef...]
);
$socket_two = Net::BitTorrent::__socket_open(q[127.0.0.1], 5500, 1, 1);
isa_ok(
    $socket_two,
    q[GLOB],
    q[   ...unless we ask to reuse the address.  In which case... [Undocumented]]
);
my ($port_two, $packed_ip_two) = unpack_sockaddr_in(getsockname($socket_two));
is($port_two, 5500, q[   ...we could accept connections on port 5500...]);
is($packed_ip_two, inet_aton(q[127.0.0.1]),
    q[   ...if we were open to the outside world.]);
is(Net::BitTorrent::__socket_open(q[127.0.0.1], 5500, q[fdsa]),
    undef, q[ReuseAddr requires a bool value...]);
is(Net::BitTorrent::__socket_open(q[127.0.0.1], 5500, 100),
    undef, q[   ...take two.]);
is(Net::BitTorrent::__socket_open(q[127.0.0.1], 5500, 1, q[fdsa]),
    undef, q[ReusePort requires a bool value... [Disabled]]);
is(Net::BitTorrent::__socket_open(q[127.0.0.1], 5500, 1, 100),
    undef, q[   ...take two.]);
diag(q[ [Alpha] __socket_open() and new() accept textual]);
diag(q[         hostnames (localhost, ganchan.somewhere.net, etc.)]);
diag(q[         which are automatically resolved.]);
isa_ok(Net::BitTorrent::__socket_open(q[localhost], 5500, 1, 1),
       q[GLOB],
       q[__socket_open(q[localhost], 5500, 1, 1) [Undocumented]]
);

#
diag(q[Testing Net::BitTorrent->_add_connection()]);

#
my $fake_client = Net::BitTorrent->new();
my $bt_ro       = Net::BitTorrent->new();
my $bt_rw       = Net::BitTorrent->new();
my $bt_wo       = Net::BitTorrent->new();
my $bt_extra    = Net::BitTorrent->new();

#
is($fake_client->_add_connection(),
    undef, q[_add_connection requires parameters]);
is($fake_client->_add_connection(undef, undef), undef, q[   Two, actually]);
is($fake_client->_add_connection(1, 2), undef,
    q[   Two, actually (take two)]);
is($fake_client->_add_connection(undef, 2),
    undef, q[   ...first a socket containing object]);
is($fake_client->_add_connection(Net::BitTorrent->new(), 2),
    undef, q[   ...first a socket containing object (take two)]);
is($fake_client->_add_connection(Net::BitTorrent->new(), 2),
    undef, q[   ...first a socket]);
is($fake_client->_add_connection(Net::BitTorrent->new(), undef),
    undef, q[   ...a mode]);
is($fake_client->_add_connection(Net::BitTorrent->new(), q[ddd]),
    undef, q[   ...a mode (take two: 'ddd')]);
is($fake_client->_add_connection(Net::BitTorrent->new(), q[road]),
    undef, q[   ...a mode (take three: 'road')]);
is($fake_client->_add_connection(Net::BitTorrent->new(), q[read]),
    undef, q[   ...a mode (take four: 'read')]);
is($fake_client->_add_connection(Net::BitTorrent->new(), q[write]),
    undef, q[   ...a mode (take five: 'write')]);
ok($fake_client->_add_connection($bt_rw, q[rw]),
    q[   ...a mode (take six: 'rw')]);
ok($fake_client->_add_connection($bt_ro, q[ro]),
    q[   ...a mode (take seven: 'ro')]);
ok($fake_client->_add_connection($bt_wo, q[wo]),
    q[   ...a mode (take eight: 'wo')]);

#
is($fake_client->_add_connection($bt_wo, q[wo]),
    undef, q[BTW, we can only add a socket once]);

#
diag(q[TODO: Check list of _sockets()]);
diag(q[Note: In reality, $client->_connections() would contain]);
diag(q[  a weak ref to $client itself; but this is a fake client.]);

#use Data::Dump qw[pp];
#warn pp $fake_client->_connections;
is(scalar(keys %{$fake_client->_connections}),
    5, q[Check list of _connections() == 3]);

#
diag(q[Testing Net::BitTorrent->_remove_connection()]);
is($fake_client->_remove_connection(),
    undef, q[_remove_connection requires one parameter:]);
is($fake_client->_remove_connection(0), undef, q[   a socket.]);
ok($fake_client->_remove_connection($bt_ro), q[Read only socket removed]);
ok($fake_client->_remove_connection($bt_rw), q[Read-write socket removed]);
ok($fake_client->_remove_connection($bt_wo), q[Write-only socket removed]);
is($fake_client->_remove_connection($bt_extra),
    undef, q[We can only remove sockets we've added]);

# In reality, $fake_client->_connections() would contain a weak ref to
# $fake_client itself... but this is a fake client.
diag(q[Checking removal of all sockets...]);
is_deeply($fake_client->_connections,
          {fileno($fake_client->_socket) => {Mode   => q[ro],
                                             Object => $fake_client
           },
           fileno($fake_client->_dht->_socket) => {
                                                  Mode   => q[ro],
                                                  Object => $fake_client->_dht
           }
          },
          q[_sockets() returns the dht object and the client itself]
);

#

ok($fake_client->do_one_loop(),
    q[   do_one_loop() accepts an optional timeout parameter...]
);
ok($fake_client->do_one_loop(1),
    q[   Timeout, if defined, must be an integer...]);
ok($fake_client->do_one_loop(1.25), q[   ...or a float...]);
is($fake_client->do_one_loop(q[test]), undef, q[   ...but not random junk.]);
is($fake_client->do_one_loop(-3),      undef, q[   ...or negative numbers.]);

#
diag(q[Reloading the sockets to test select() (We don't actually use these)]);
ok($fake_client->_add_connection($bt_rw, q[rw]), q[   RW socket added)]);
ok($fake_client->_add_connection($bt_ro, q[ro]), q[   RO socket added)]);
ok($fake_client->_add_connection($bt_wo, q[wo]), q[   WO socket added]);

#
diag(  q[This next bit (tries) to create a server, client, and ]
     . q[the accepted loopback...]);
diag(q[Think happy thoughts.]);

#
diag(q[Testing Net::BitTorrent->new()]);
my $client_no_params = Net::BitTorrent->new();
isa_ok($client_no_params, q[Net::BitTorrent], q[new( )]);

#
is(Net::BitTorrent->new(LocalPort => [20502 .. 20505]),
    undef, q[new(LocalPort => [20502..20505]) returns undef]);
is(Net::BitTorrent->new([20502 .. 20505]),
    undef, q[new([20502..20505]) returns undef]);
is(Net::BitTorrent->new(q[0.0.0.0:20502]),
    undef, q[new(q[0.0.0.0:20502]) returns undef]);

#
isa_ok(Net::BitTorrent->new({}), q[Net::BitTorrent], q[new({ })]);
isa_ok(Net::BitTorrent->new({LocalPort => 20502}),
       q[Net::BitTorrent],
       q[new({LocalPort => 20502})]
);
is(Net::BitTorrent->new({LocalPort => $client->_port}),
    undef, sprintf q[new({LocalPort => %d}) (Attempt to reuse port)],
    $client->_port);
is( Net::BitTorrent->new(
                      {LocalPort => $client->_port, LocalAddr => q[127.0.0.1]}
    ),
    undef,
    sprintf q[Attempt to reuse address (Undocumented)],
    $client->_port
);
isa_ok(
      Net::BitTorrent->new({LocalPort => $client->_port,
                            LocalAddr => q[127.0.0.1],
                            ReuseAddr => 1
                           }
      ),
      q[Net::BitTorrent],
      sprintf
          q[Attempt to reuse address with undocumented ReuseAddress argument],
      $client->_port
);

# Uses 20502 so $client_list_port is forced to use 20505
my $client_range_port = Net::BitTorrent->new({LocalPort => [20502 .. 20505]});
isa_ok($client_range_port, q[Net::BitTorrent],
       q[new({LocalPort => [20502 .. 20505]})]);
my $client_list_port = Net::BitTorrent->new({LocalPort => [20502, 20505]});
isa_ok($client_list_port, q[Net::BitTorrent],
       q[new({LocalPort => [20502, 20505]})]);

#
my $socket = $client_list_port->_socket;
isa_ok($client_list_port->_socket, q[GLOB], q[Socket is valid.]);
my ($port, $packed_ip)
    = unpack_sockaddr_in(getsockname($client_list_port->_socket));
is($port, 20505, q[Correct port was opened (20505).]);

#
like($client_list_port->peerid, qr[^NB\d{3}[CS]-.{8}.{5}$],
     q[Peer ID conforms to spec.]);
diag(q[Testing Net::BitTorrent->add_session()]);
is($client->add_session(q[./t/900_data/950_torrents/952_multi.torrent]),
    undef, q[Needs hash ref params]);
$session = $client->add_session(
                      {Path => q[./t/900_data/950_torrents/952_multi.torrent],
                       BaseDir => $tempdir
                      }
);
isa_ok($session, q[Net::BitTorrent::Session], q[Added session]);
is_deeply($client->sessions,
          {$$session => $session},
          q[Net::BitTorrent correctly stores sessions]);
is( $client->add_session(
                      {Path => q[./t/900_data/950_torrents/952_multi.torrent]}
    ),
    undef,
    q[   ...but only once.]
);
is_deeply($client->sessions,
          {$$session => $session},
          q[   (Double check that to be sure)]);
ok($client->remove_session($session), q[Attempt to remove session]);
is($client->remove_session(q[Junk!]),
    undef, q[Attempt to remove not-a-session]);
is_deeply($client->sessions, {}, q[   CHeck if session was removed]);

#use Data::Dump qw[pp];
#warn pp $client->sessions();
#warn pp $client->_connections;
ok($client->do_one_loop, q[do_one_loop]);
like($client->_peers_per_session, qr[^\d+$],
     q[_peers_per_session() is a number]);

#
#use Devel::Peek;
#Dump \$client;
#use Data::Dump qw[pp];
#use Devel::FindRef;warn Devel::FindRef::track $client;