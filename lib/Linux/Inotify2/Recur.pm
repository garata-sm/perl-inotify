package Linux::Inotify2::Recur;

use strict;
use base 'Linux::Inotify2';
# ToDo? - how to import IN_MODIFY and others?
use Linux::Inotify2;

use File::Find;
use Time::HiRes qw(time);

=head1 NAME

Linux::Inotify2::Recur - recursive directory/file change notification

=head1 SYNOPSIS

=head2 Callback Interface

 use Linux::Inotify2::Recur;

 # create a new object
 my $inotify = new Linux::Inotify2::Recur({
    'ver' => $ver,

 }) or die "Unable to create new inotify object: $!\n";

 # manual event loop
 1 while $inotify->poll;

=head1 Verbosity levels

 0 ... nothing
 1 ... fatal errors
 2 ... short info
 3 ... base info (default)
 ...
 8 ... all debug info
 9 ... too many debug info

=cut

sub new {
    my ( $class, $conf ) = @_;

    my $self = $class->SUPER::new();

    # Verbosity level
    $self->{ver} = 3;
    $self->{ver} = $conf->{ver} if defined $conf->{ver};

    # User defined subroutine to filter directories to watch.
    $self->{grep_dirs_sub} = undef;
    $self->{grep_dirs_sub} = $conf->{grep_dirs_sub} if defined $conf->{grep_dirs_sub};

    # User defined subroutine to run after event occurs.
    $self->{my_event_handle} = undef;
    $self->{my_event_handle} = $conf->{my_event_handle} if defined $conf->{my_event_handle};

    # User defined subroutine to run on Linux::Inotify2 base constructor instance time.
    $self->{grep_masks_sub} = undef;
    $self->{grep_masks_sub} = $conf->{greb_masks_sub} if defined $conf->{grep_masks_sub};

    # Initialize vars.
    $self->{cookies_to_rm} = {};

    $self->load_ev_names() if $self->{ver} >= 3;
    $self->set_watcher_sub();

    return $self;
}


sub load_ev_names {
    my ( $self ) = @_;

    print "Events:\n" if $self->{ver} >= 5;
    no strict 'refs';
    for my $name (@Linux::Inotify2::EXPORT) {
       my $mask = &{"Linux::Inotify2::$name"};
       $self->{ev_names}->{$mask} = $name;
       print "   $name $mask\n" if $self->{ver} >= 5;
    }
    use strict 'refs';
    print "\n" if $self->{ver} >= 5;
}


sub dump_watched {
    my ( $self, $msg ) = @_;

    print "Watch list";
    print ' - ' . $msg if $msg;
    print ":\n";

    my $watchers = $self->{w};
    foreach my $key ( sort { $a <=> $b } keys %$watchers ) {
        my $watcher = $watchers->{ $key };
        print '   ' . $key . ' - ' . $watcher->{name} . ' : ' . $watcher->{mask} . "\n";
    }

    print "\n";
    return 1;
}


sub inotify_watch {
    my ( $self, $dir, $initial_run ) = @_;

    print "Watching '$dir'\n" if $self->{ver} >= 4;

    $! = undef;
    my $watcher = $self->watch(
        $dir,
        $self->watch_these( $dir ),
        $self->{watcher_sub}
    );

    $self->{num_to_watch}++;
    if ( $watcher ) {
        $self->{num_watched}++;
    } else {
        print "Error adding watcher: $!\n" if $self->{ver} >= 1;
    }
    $self->dump_watched('added/moved') if ( $self->{ver} >= 9 || ( $self->{ver} >= 8 && !$initial_run ));
    return $watcher;
}


sub watch_these {
    my ( $self, $dir ) = @_;

    my $default = ( IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE | IN_DELETE | IN_IGNORED | IN_UNMOUNT | IN_DELETE_SELF );

    return $default unless -d $dir;

    if ( defined $self->{grep_masks_sub} ) {
        return $self->{grep_masks_sub}->( $dir );
    }
    return $default;
}


sub watch_this {
    my ( $self, $dir ) = @_;

    return 0 unless -d $dir;

    if ( defined $self->{grep_dirs_sub} ) {
        return 0 unless $self->{grep_dirs_sub}->( $dir );
    }
    return 1;
}


sub item_to_watch {
    my ( $self, $dir, $initial_run ) = @_;
    return undef unless $self->watch_this( $dir );
    return $self->inotify_watch( $dir, $initial_run );
}


sub items_to_watch_recursive {
    my ( $self, $dirs_to_watch, $initial_run ) = @_;

    # Add watchers.
    return finddepth( {
            wanted => sub {
                $self->item_to_watch( $_, $initial_run );
            },
            no_chdir => 1,
        },
        @$dirs_to_watch
    );
}


sub item_to_remove_by_name {
    my ( $self, $item_torm_base, $recursive ) = @_;

    my $ret_code = 1;

    # Removing by name.
    my $item_torm_len = length( $item_torm_base );
    foreach my $watch ( values %{ $self->{w} } ) {
        my $remove = 0;
        my $item_name = $watch->{name};
        if ( $recursive ) {
            if ( length($item_name) >= $item_torm_len
                 && substr($item_name,0,$item_torm_len) eq $item_torm_base
            ) {
                $remove = 1;
            }

        } else {
            $remove = 1 if $item_name eq $item_torm_base;
        }

        if ( $remove ) {
            print "Stopping watching $item_name (by name '$item_torm_base', rec: $recursive).\n" if $self->{ver} >= 4;
            my $tmp_ret_code = $watch->cancel;
            $self->dump_watched('removed by name') if $self->{ver} >= 8;
            $ret_code = 0 unless $tmp_ret_code;
        }
    }

    return $ret_code;
}


sub item_to_remove_by_event {
    my ( $self, $item, $e, $recursive ) = @_;

    # Removing by object ref.
    print "Stopping watching $item (by object).\n" if $self->{ver} >= 5;
    my $ret_code = 1;
    if ( $recursive ) {
        my $items_inside_prefix = $item . '/';
        $ret_code = $self->item_to_remove_by_name( $items_inside_prefix, $recursive );
    }
    my $tmp_ret_code = $e->{w}->cancel;
    $ret_code = 0 unless $tmp_ret_code;
    $self->dump_watched('removed by ref') if $self->{ver} >= 8;
    return $ret_code;

    print "Error: Can't remove item '$item' (not found).\n" if $self->{ver} >= 1;
    return 0;
}


sub set_watcher_sub {
    my ( $self ) = @_;

    my $last_time = 0;
    $self->{watcher_sub} = sub {
        my $e = shift;

        my $time = time();
        my $fullname = $e->fullname;

        # Print event info.
        if ( $self->{ver} >= 2 ) {
            # Print line separator only each second.
            if ( int($time) != $last_time ) {
                print "-" x 80 . "\n" if $self->{ver} >= 3;
                $last_time = int($time);
            }

            my @lt = localtime($time);
            my $dt = sprintf("%02d.%02d.%04d %02d:%02d:%02d -", $lt[3], ($lt[4] + 1),( $lt[5] + 1900), $lt[2], $lt[1], $lt[0] );
            print $dt;

            if ( $self->{ver} >= 3 ) {
                my $mask = $e->{mask};
                if ( defined $mask ) {
                    if ( defined $self->{ev_names}->{$mask} ) {
                        print " " . $self->{ev_names}->{$mask};
                    } else {
                        foreach my $ev_mask (keys %{$self->{ev_names}}) {
                            if ( ($mask & $ev_mask) == $ev_mask ) {
                                my $name = $self->{ev_names}->{ $ev_mask };
                                print " $name";
                            }
                        }
                    }
                }
            }

            print ' -- ' . $fullname;
            print ' (' . $e->{name} . ')' if $e->{name};
            print ", cookie: '" . $e->{cookie} . "'" if $self->{ver} >= 3 && $e->{cookie};
            print "\n";
        }

        my $is_dir = ( $e->{mask} & IN_ISDIR );
        my $moved_from = undef;
        if ( $e->IN_CREATE ) {
            if ( $is_dir ) {
                $self->items_to_watch_recursive( [ $fullname ], 0 );
            }

        } elsif ( $e->IN_MOVED_TO ) {
            my $cookie = $e->{cookie};
            if ( exists $self->{cookies_to_rm}->{$cookie} ) {
                if ( $self->{cookies_to_rm}->{$cookie}->[0] ) {
                    # Check if we want to watch new name.
                    if ( $self->watch_this($fullname) ) {
                        # Update path inside existing watch.
                        $self->items_to_watch_recursive( [ $fullname ], 0 );
                        $moved_from = $self->{cookies_to_rm}->{$cookie}->[1];
                        delete $self->{cookies_to_rm}->{$cookie};

                    # Remove old watch if exists.
                    } elsif ( defined $self->{cookies_to_rm}->{$cookie} ) {
                        my $c_fullname = $self->{cookies_to_rm}->{$cookie};
                        $self->item_to_remove_by_name( $c_fullname, 1 );
                        $moved_from = $self->{cookies_to_rm}->{$cookie}->[1];
                        delete $self->{cookies_to_rm}->{$cookie};

                    # Remember new cookie.
                    } else {
                        $self->{cookies_to_rm}->{ $e->{cookie} } = undef;
                    }

                } else {
                    $moved_from = delete $self->{cookies_to_rm}->{$cookie}->[1];
                }

            } else {
                $self->items_to_watch_recursive( [ $fullname ], 0 );
            }
        }


        if ( defined $self->{my_event_handle} ) {
            $self->{my_event_handle}->(
                $time,
                $fullname,
                $e,
                $self->{ver},
                $moved_from
            );
        }


        # Event on directory, but item inside changed.
        if ( length($e->{name}) ) {
            # Directory moved away.
            if ( $e->{mask} & IN_MOVED_FROM ) {
                my $cookie = $e->{cookie};
                if ( exists $self->{cookies_to_rm}->{$cookie} ) {
                    # Nothing to do. See assumption a).
                    print "Warning: Probably moved_from after moved_to occurs.\n" if $self->{ver} >= 1;
                } else {
                    # We don't know new name yet, so we can't decide what to do (update or remove watch).
                    # See assumption b).
                    my $is_watched = $is_dir;
                    $self->{cookies_to_rm}->{ $cookie } = [ $is_watched, $fullname ];
                }
            }

        # Event on item itself.
        } elsif ( $e->{mask} & (IN_IGNORED | IN_UNMOUNT | IN_ONESHOT | IN_DELETE_SELF) ) {
            $self->item_to_remove_by_event( $fullname, $e, 1 );
        }

        $self->dump_watched('actual list') if $self->{ver} >= 9;
        return 1;
    };

    return 1;
}


sub add_dirs {
    my ( $self, $dirs_to_watch ) = @_;

    $self->{num_watched} = 0;
    $self->{num_to_watch} = 0;

    $self->items_to_watch_recursive( $dirs_to_watch, 1 );

    if ( $self->{num_to_watch} != $self->{num_watched} ) {
        print "Watching only $self->{num_watched} of $self->{num_to_watch} dirs.\n\n" if $self->{ver} >= 3;
    } else {
        print "Now watching all $self->{num_watched} dirs.\n\n" if $self->{ver} >= 3;
    }

    return 1;
}


sub cleanup_moved_out {
    my ( $self ) = @_;

    return 1 unless scalar keys %{ $self->{cookies_to_rm} };

    # Remove all IN_MOVE_FROM without IN_MOVE_TO.
    foreach my $cookie ( keys %{ $self->{cookies_to_rm} } ) {
       if ( defined $self->{cookies_to_rm}->{$cookie} ) {
            next unless $self->{cookies_to_rm}->{$cookie}->[0]; # check is_watched
            my $fullname = $self->{cookies_to_rm}->{$cookie};
            print "After loop cleanup - fullname '$fullname'.\n" if $self->{ver} >= 5;
            $self->item_to_remove_by_name( $fullname, 0 );
            my $items_inside_prefix = $fullname . '/';
            $self->item_to_remove_by_name( $items_inside_prefix, 1 );
            delete $self->{cookies_to_rm}->{$cookie};
       }
    }
    return 1;
}


sub pool {
    my ( $self ) = @_;

    $! = undef;
    my @events = $self->read;
    if ( @events > 0 ) {
        $self->cleanup_moved_out();
        return 1;
    }

    print "Error: Event read error - $!\n" if $self->{ver} >= 1 && $!;
    return 1;
}

=head1 Assumptions

 a) No MOVED_TO, MOVED_FROM order.
 b) No items related events between MOVED_FROM and MOVED_TO.

=head1 Troubleshooting

=head2 Error "no space left on device"

See Kernel Korner - Intro to inotify, Sep 28 2005, Robert Love, Linux Journal (L<http://www.linuxjournal.com/article/8478?page=0,3>)

Commands like

    cat /proc/sys/fs/inotify/max_queued_events
    cat /proc/sys/fs/inotify/max_user_watches

    echo 65536 > /proc/sys/fs/inotify/max_queued_events
    echo 32768 > /proc/sys/fs/inotify/max_user_watches

should help.

=head1 See also

L<Linux::Inotify2|Linux::Inotify2> CPAN module.

=head1 Author

Michal Jurosz - L<irc://irc.freenode.org/#mj41> - email: mj{$zav}mj41.cz

=cut

1;