package Linux::Inotify2::Recur;

use strict;
use warnings;

use base 'Linux::Inotify2';

# ToDo? - how to import IN_MODIFY and others?
use Linux::Inotify2;

use File::Find;


=head1 NAME

Linux::Inotify2::Recur - recursive directory/file change notification

=head1 SYNOPSIS

=head2 Callback Interface

 use Linux::Inotify2::Recur;
 
 # create a new object
 my $inotify = new Linux::Inotify2::Recur( $verbosity_level )
    or die "Unable to create new inotify object: $!\n";

 # manual event loop
 1 while $inotify->poll;

=head1 Verbosity levels

 0 ... nothing
 1 ... fatal errors
 2 ... short info
 3 ... base info
 ...
 9 ... all debug info
 
=head1 Assumptions

 a) No MOVED_TO, MOVED_FROM order.
 b) No items related events between MOVED_FROM and MOVED_TO.
 c) MOVED_FROM and MOVED_TO not in two separated "$inotify->read"s.

=cut

sub new {
    my ( $class, $ver ) = @_;

    my $self = $class->SUPER::new();
    
    $self->{ver} = 3;
    $self->{ver} = $ver if defined $ver;
    
    # Verbosity level
    
    $self->load_ev_names() if $self->{ver} >= 3;
    
    $self->{cookies_to_rm} = {};
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
    my ( $self, $dir ) = @_;

    print "Watching '$dir'\n" if $self->{ver} >= 4;

    my $watcher = $self->watch(
        $dir,
        ( IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE | IN_DELETE | IN_IGNORED | IN_UNMOUNT | IN_DELETE_SELF ),
        $self->{watcher_sub}
    );

    $self->{num_to_watch}++;
    if ( $watcher ) {
        $self->{num_watched}++;
    } else {
        print "Error adding watcher: $!\n" if $self->{ver} >= 1;
    }
    $self->dump_watched('added new') if $self->{ver} >= 8;
    return $watcher;
}


sub watch_this {
    my ( $self, $dir ) = @_;

    return 0 unless -d $dir;

    # Do not watch version control dirs.
    #return 0 if $dir =~ m{/.svn$/};
    #return 0 if $dir =~ m{/\.svn/};

    # Inside temp directory.
    #return 0 if $dir =~ m{/temp/};

    return 1;

}


sub item_to_watch {
    my ( $self, $dir ) = @_;
    return undef unless $self->watch_this( $dir );
    return $self->inotify_watch( $dir );
}


sub items_to_watch_recursive {
    my ( $self, $dirs_to_watch ) = @_;

    # Add watchers.
    return finddepth( {
            wanted => sub {
                $self->item_to_watch( $_ );
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

        if (    $fullname =~ m{/\.swp$} # vi editor backup
             || $fullname =~ m{/\.swx$} # vi editor backup
             # || $fullname =~ m{/tempfile\.tmp$} # svn update tempfile
        ) {
            print "Skipping '$fullname'.\n" if $self->{ver} >= 5;

        }  else {
            if ( $e->IN_CREATE ) {
                $self->items_to_watch_recursive( [ $fullname ] );
                
            } elsif ( $e->IN_MOVED_TO ) {
                my $cookie = $e->{cookie};
                if ( exists $self->{cookies_to_rm}->{$cookie} ) {
                    # Check if we want to watch new name.
                    if ( $self->watch_this($fullname) ) {
                        # Update path inside existing watch.
                        $self->items_to_watch_recursive( [ $fullname ] );
                        delete $self->{cookies_to_rm}->{$cookie};

                    # Remove old watch if exists.
                    } elsif ( defined $self->{cookies_to_rm}->{$cookie} ) {
                        my $c_fullname = $self->{cookies_to_rm}->{$cookie};
                        $self->item_to_remove_by_name( $c_fullname, 1 );
                        delete $self->{cookies_to_rm}->{$cookie};

                    # Remember new cookie.
                    } else {
                        $self->{cookies_to_rm}->{ $e->{cookie} } = undef;
                    }

                } else {
                    $self->items_to_watch_recursive( [ $fullname ] );
                }
            }

            if ( $self->{ver} >= 2 ) {
                my @lt = localtime($time);
                my $dt = sprintf("%02d.%02d.%04d %02d:%02d:%02d -", $lt[3], ($lt[4] + 1),( $lt[5] + 1900), $lt[2], $lt[1], $lt[0] );
                print $dt . ' ';

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

            # Print line separator only each second.
            if ( int($time) != $last_time ) {
                print "-" x 80 . "\n" if $self->{ver} >= 3;
                $last_time = int($time);
            }
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
                    $self->{cookies_to_rm}->{ $cookie } = $fullname;
                }
            }

        # Event on item itself.
        } elsif ( $e->{mask} & (IN_IGNORED | IN_UNMOUNT | IN_ONESHOT | IN_DELETE_SELF) ) {
            $self->item_to_remove_by_event( $fullname, $e, 1 );
        }

        $self->dump_watched('actual list') if $self->{ver} >= 8;
        return 1;
    };

    return 1;
}


sub add_dirs {
    my ( $self, $dirs_to_watch ) = @_;

    $self->{num_watched} = 0;
    $self->{num_to_watch} = 0;

    $self->items_to_watch_recursive( $dirs_to_watch );

    if ( $self->{num_to_watch} != $self->{num_watched} ) {
        print "Watching only $self->{num_watched} of $self->{num_to_watch} dirs.\n" if $self->{ver} >= 3;
    } else {
        print "Now watching all $self->{num_watched} dirs.\n" if $self->{ver} >= 3;
    }

    return 1;
}


sub cleanup_moved_out {
    my ( $self ) = @_;

    return 1 unless scalar keys %{ $self->{cookies_to_rm} };

    # Remove all IN_MOVE_FROM without IN_MOVE_TO. See assumption c).
    foreach my $cookie ( keys %{ $self->{cookies_to_rm} } ) {
       if ( defined $self->{cookies_to_rm}->{$cookie} ) {
            my $fullname = $self->{cookies_to_rm}->{$cookie};
            print "After loop cleanup - fullname '$fullname'.\n" if $self->{ver} >= 4;
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

1;