use strict;
use warnings;


use Carp qw(carp croak verbose);
use Data::Dumper;
use Time::HiRes qw(time sleep);
use POSIX;
use File::Find;

use lib 'lib';
use Linux::Inotify2;


my $devel = ! $ARGV[0];

# Verbosity level.
my $ver = 8;
$ver = 2 unless $devel;
$ver = $ARGV[1] if $ARGV[1];


my $dirs_to_watch = [];

$dirs_to_watch = [
    '/home/mj/',
];

if ( $devel ) {
    print "Running in devel mode. Verbose level $ver.\n";
    $dirs_to_watch = [
        './test-dir',
    ];
}


# create a new object
my $inotify = new Linux::Inotify2
    or croak "Unable to create new inotify object: $!";


my $ev_names = {};
print "Events:\n" if $ver >= 5;
no strict 'refs';
for my $name (@Linux::Inotify2::EXPORT) {
   my $mask = &{"Linux::Inotify2::$name"};
   $ev_names->{$mask} = $name;
   print "   $name $mask\n" if $ver >= 5;
}
use strict 'refs';
print "\n" if $ver >= 5;


my $svn_su_prefix = 'su vyvoj -c"';
my $svn_su_suffix = '"';
my $svn_cmd_prefix = '/usr/bin/';


sub svn_diff {
    my ( $item ) = @_;

    my $svndiff_cmd =
        $svn_su_prefix
        . $svn_cmd_prefix . 'svn diff ' . $item
        . $svn_su_suffix
        . ' 2>&1 |'
    ;

    unless ( open( SVNDIFF, $svndiff_cmd ) ) {
        return ( 0, $! );
    }

    my @lines = ();
    while ( my $line = <SVNDIFF> ) { push @lines, $line };
    close SVNDIFF;

    my $no_exists = 0;
    if ( scalar(@lines) <= 0 ) {
        print "Empty svn diff.\n" if $ver >= 5;

    } elsif ( $lines[0] =~ /is\ not\ under\ version\ control$/ ) {
        print "Not in svn.\n" if $ver >= 5;

    } elsif ( $lines[0] =~ /is\ not\ a\ working\ copy$/ ) {
        print "Not svn dir.\n"  if $ver >= 5;

    } elsif (    $lines[0] =~ m{^Index\:\s+}
              && $lines[1] =~ m{^\={20,}}
              && $lines[2] =~ m{^\-\-\-\s+}
              && $lines[3] =~ m{^\+\+\+\s+}
              && $lines[4] =~ m{^\@\@\s+}
    ) {
        print "Svn diff found.\n" if $ver >= 5;
        if ( $ver >= 8 ) {
            print join( '', @lines );
            print "-" x 80 . "\n";
        }

        my $plus_str = '';
        my $minus_str = '';
        my $lines_count_diff = 0;
        my $lines_count_modif = 0;
        foreach my $line_num (5..$#lines) {
            my $line = $lines[$line_num];
            my $first_char = substr( $line, 0, 1 );

            if ( $first_char eq '-' || $first_char eq '+' ) {

               $line = substr( $line, 1 );
               $line =~ s{[\s\n\t\r]}{}g;

               $lines_count_modif++ if length($line) > 0;;
               if ( $first_char eq '-' ) {
                    $minus_str .= $line;
                    $lines_count_diff-- if length($line) > 0;
                } else {
                    $plus_str .= $line;
                    $lines_count_diff++ if length($line) > 0;
                }
            }
        }
        print "-$minus_str\n" if $ver >= 9;
        print "+$plus_str\n" if $ver >= 9;;

        my $len_diff = length($plus_str) - length($minus_str);
        print "  str len change: $len_diff, lines num diff: $lines_count_diff, lines num modif: $lines_count_modif\n" if $ver >= 2;

    } else {
        print "Svn diff - unknown.\n" if $ver >= 5;
        print join( '', @lines );
    }
    return ( 1, 'ok' );
}


sub mdump {
    my ( $data ) = @_;
    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Sortkeys = 1;
    return Data::Dumper->Dump( [ $data ], [] ) . "\n";
}


sub dump_watched {
    my ( $inotify, $msg ) = @_;


    print "Watch list";
    print ' - ' . $msg if $msg;
    print ":\n";

    my $watchers = $inotify->{w};
    foreach my $key ( sort { $a <=> $b } keys %$watchers ) {
        my $watcher = $watchers->{ $key };
        print '   ' . $key . ' - ' . $watcher->{name} . ' : ' . $watcher->{mask} . "\n";
    }

    print "\n";

    return 1;
}


my $watcher_sub;
my $num_watched = 0;
my $num_to_watch = 0;
sub inotify_watch {
    my ( $dir ) = @_;

    print "Watching $dir\n" if $ver >= 8;

    my $watcher = $inotify->watch(
        $dir,
        ( IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE | IN_DELETE | IN_IGNORED | IN_UNMOUNT | IN_DELETE_SELF ),
        $watcher_sub
    );

    $num_to_watch++;
    if ( $watcher ) {
        $num_watched++;
    } else {
        print "Error adding watcher: $!\n";
    }
    dump_watched( $inotify, 'added new' ) if $ver >= 10;
    return $watcher;
}


sub item_to_watch {
    my ( $dir ) = @_;

    return undef unless -d $dir;
    return undef if $dir =~ '/.svn$';
    return undef if $dir =~ '/\.svn/';

    unless ( $devel ) {
        return undef if $dir =~ m'{/jurosz2/}';
        return undef if $dir =~ m'{/jurosz2$}';
    }

    return inotify_watch( $dir );
}


sub item_to_remove {
    my ( $inotify, $item, $e ) = @_;


    # Removing by object ref.
    if ( defined $e ) {
        print "Stopping watching $item (by object).\n" if $ver >= 5;
        my $ret_code = $e->{w}->cancel;
        dump_watched( $inotify, 'removed by ref' ) if $ver >= 10;
        return $ret_code;
    }

    # Removing by name.
    foreach my $watch ( values %{ $inotify->{w} } ) {
        if ( $watch->{name} eq $item ) {
            print "Stopping watching $item (by name).\n" if $ver >= 5;
            #print mdump( $watch );
            my $ret_code = $watch->cancel;
            dump_watched( $inotify, 'removed by name' ) if $ver >= 10;
            return $ret_code;
        }
    }

    print "Error: Can't remove item '$item' (not found).\n" if $ver >= 1;
    return 0;
}


my $last_time = 0;
$watcher_sub = sub {
    my $e = shift;

    my $time = time();
    my $fullname = $e->fullname;

    if (    $fullname =~ m{/tempfile\.tmp$} # svn update tempfile
         || $fullname =~ m{/app_revisions\.svni$} # generated
         || $fullname =~ m{/\.swp$} # vi editor backup
         || $fullname =~ m{/\.swx$} # vi editor backup
    ) {
        print "Skipping '$fullname'.\n" if $ver >= 5;

    }  else {
        if ( ($e->IN_CREATE || $e->IN_MOVED_TO) && $e->IN_ISDIR ) {
            my $watcher = item_to_watch( $fullname );
        }

        my @lt = localtime($time);
        my $dt = sprintf("%02d.%02d.%04d %02d:%02d:%02d -", $lt[3], ($lt[4] + 1),( $lt[5] + 1900), $lt[2], $lt[1], $lt[0] );
        print $dt . ' ';

        my $mask = $e->{mask};
        if ( defined $mask ) {
            if ( defined $ev_names->{$mask} ) {
                print " " . $ev_names->{$mask};
            } else {
                foreach my $ev_mask (keys %$ev_names) {
                    if ( ($mask & $ev_mask) == $ev_mask ) {
                        my $name = $ev_names->{ $ev_mask };
                        print " $name";
                    }
                }
            }
        }

        print ' -- ' . $fullname;
        print ' (' . $e->{name} . ')' if $e->{name};
        print ", cookie: '" . $e->{cookie} . "'" if $e->{cookie};
        print "\n";

        if ( ! $e->IN_ISDIR ) {
            my ( $rc, $msg ) = svn_diff( $fullname );
            print "rc: $rc, msg: $msg\n" if $ver >= 9;
        }

        # Print line separator only each second.
        if ( floor($time) != $last_time ) {
            print "-" x 80 . "\n";
            $last_time = floor($time);
        }
    }


    # Event on directory, but item inside changed.
    if ( length($e->{name}) ) {
        # Directory moved away.
        if ( ($e->{mask} & IN_MOVED_FROM) && $e->IN_ISDIR ) {
            # ToDo - if used, then exit
            #item_to_remove( $inotify, $fullname );
        }

    # Event on item itself.
    } elsif ( $e->{mask} & (IN_IGNORED | IN_UNMOUNT | IN_ONESHOT | IN_DELETE_SELF) ) {
        item_to_remove( $inotify, $fullname, $e );
    }

    dump_watched( $inotify, 'actual list' ) if $ver >= 9;

    return 1;
};



# Add watchers.
finddepth( {
        wanted => sub {
            item_to_watch( $_ );
        },
        no_chdir => 1,
    },
    @$dirs_to_watch
);

if ( $num_to_watch != $num_watched ) {
    print "Watching only $num_watched of $num_to_watch dirs.\n";
} else {
    print "Now watching all $num_watched dirs.\n";
}


# Main event loop.
if ( 1 ) {
    1 while $inotify->poll;
} else {
    $inotify->blocking(0);
    while ( 1 ) {
        $inotify->poll;
        sleep(0.01);
    }
}