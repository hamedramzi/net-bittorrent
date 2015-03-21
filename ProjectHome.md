Net::BitTorrent brings BitTorrent to Perl.  Bet::BitTorrent is available via [CPAN](http://search.cpan.org/dist/Net-BitTorrent/).

# News #
**(Apr. 24th, 2009)** URL shakeup; Spring 2009 Edition.
  * Issue/Bug tracking has been moved to [GitHub](http://github.com/): http://github.com/sanko/net-bittorrent/issues
  * Live support is now available via IRC on both freenode and the p2p network. Join [irc://irc.freenode.org/#net-bittorrent](irc://irc.freenode.org/#net-bittorrent) or [irc://irc.p2p-network.net/#net-bittorrent](irc://irc.p2p-network.net/#net-bittorrent).

**(Jan. 26th, 2009)** URL shakeup.
  * Development has been moved to [GitHub](http://github.com); the repository is now at http://github.com/sanko/net-bittorrent.
  * The mailing lists have been merged; please see http://groups.google.com/group/net-bittorrent/.
  * Live support is now available via IRC; join <a href='irc://irc.p2p.network.net/#net-bittorrent'>#net-bittorrent on irc.p2p-network.net</a>.
  * Occasional Net::BitTorrent-related blog entries can be found on my site http://sankorobinson.com/?tag=Net::BitTorrent ([ATOM](http://sankorobinson.com/atom/?tag=Net::BitTorrent))
  * The issue tracker is still at the old address here on GoogleCode: http://code.google.com/p/net-bittorrent/issues/list.

---

## Features include... ##
  * Proven [portability](http://bbbike.radzeit.de/~slaven/cpantestersmatrix.cgi?dist=Net-BitTorrent;maxver=1).
  * Written in pure Perl. No compiler needed.
  * [Well documented API](http://search.cpan.org/perldoc?Net::BitTorrent) and a clean, class-based design.
  * Doesn't depend on any 'extra' modules.  If you have perl 5.10, you're set.
  * International support; Unicode filenames are properly handled even on Win32.
  * Support for many major extensions to the [base protocol](http://bittorrent.org/beps/bep_0003.html) including the [Fast (Peers) Extension](http://bittorrent.org/beps/bep_0006.html) and [Mainline DHT](http://bittorrent.org/beps/bep_0005.html).

## Getting Started... ##
Getting a full client up and running with Net::BitTorrent is easy. Simply...
  1. Pick an installation method:
    * CPAN shell: `cpan Net::BitTorrent`
    * PPM shell: `ppm install Net::BitTorrent` _(Note: I suggest using [ActiveState's beta repositories](http://ppm.activestate.com/beta/).)_
    * Manually (from a [Subversion checkout](http://code.google.com/p/net-bittorrent/source/checkout) or extracted [.tar.gz](http://search.cpan.org/CPAN/authors/id/S/SA/SANKO/)): `perl ./Build.PL && ./Build && ./Build test && ./Build install`
  1. Type "`perldoc Net::BitTorrent`" at the command line for documentation and a very simple working client.

For more complete sample clients, see [client.pl](http://code.google.com/p/net-bittorrent/source/browse/trunk/scripts/client.pl) and [web-gui.pl](http://code.google.com/p/net-bittorrent/source/browse/trunk/scripts/web-gui.pl); these two files are also bundled with the Net::BitTorrent distribution but are not installed.

---

For more geeky stuff, see [my other repository here on GoogleCode](http://sanko.googlecode.com/)... There, you'll find (among other things) [perl4mIRC](http://code.google.com/p/sanko/downloads/list?q=perl4mIRC).