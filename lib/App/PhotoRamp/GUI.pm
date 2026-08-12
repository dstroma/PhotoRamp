use v5.34;
use experimental 'signatures';
package PIH::GUI {
  use Gtk3 -init;
  use Glib;
  use FindBin;
  
  use constant FALSE => !1;
  use constant TRUE  => !0;
  use constant TIMEOUT_REPEAT => TRUE();
  use constant TIMEOUT_FINISH => FALSE();
  use constant IS_RUNNING => 0;
  
  #sub show_progress_dialg (%params) {
  #  my $cancel = $params{'cancel'};
  #}
  
  #sub show_ok_dialg (%params) {
  #  my $message = $params{'message'};
  #}
  
  sub show_dialog (%params) {
    my $title   = $params{'title'}   // '';
    my $message = $params{'message'} // '';
    my $buttons = $params{'buttons'} // [];
    my $parent  = $params{'parent'};
   #my $modal   = $params{'modal'} ? 1 : 0;
 
    # Cleanup
    die 'show_dialog(buttons => [])'
      if $buttons and not ref $buttons eq 'ARRAY';
    
    # Create dialog
    my $dial = Gtk3::Dialog->new($title, $parent, 'modal');
    my $hbox = Gtk3::Box->new('horizontal', 20);
    $hbox->set_border_width(10);

    # Add message
    my $labl = Gtk3::Label->new;
    $labl->set_text($message);
    $hbox->add($labl);  
    $dial->get_content_area->set_border_width(5);
    $dial->get_content_area->add($hbox);
    
    # Syntactic sugar for Cancel and OK
    unshift @$buttons, { label => 'Cancel', action => $params{'cancel'} } if $params{'cancel'};
    unshift @$buttons, { label => 'OK',     action => $params{'ok'} }     if $params{'ok'};
    
    # Add buttons to the dialog
    $dial->add_button($buttons->[$_]{'label'}, $_) for 0 .. $#$buttons;

    # Add the hooks
    $dial->signal_connect('response' => sub ($this_dial, $id, @slurp) {
      $buttons->[$id]{'action'} -> ($this_dial, @slurp) if $buttons->[$id];
    });
        
    $dial->show_all;
  }
 
  sub main {
    my $window = Gtk3::Window->new('toplevel');
    $window->set_title('Photo Import Helper by DMS');
    $window->set_position('center');
    $window->set_default_size(500,300);
    $window->set_border_width(10);
 
    my @buttons = ();
    #{ 
    #  my $button = Gtk3::Button->new('Check My Computer for Duplicates');
    #  $button->signal_connect(clicked => \&check_for_duplicates);
    #  push @buttons, $button;
    #}
    {
      my $button = Gtk3::Button->new('Process and Import from Memory Card');
      $button->signal_connect(clicked => sub { import_from_memory_card($window) });
      push @buttons, $button;
    }
    #{
    #  my $button = Gtk3::Button->new('Pick and Choose Import from Memory Card');
    #  $button->signal_connect(clicked => \&import_cherry_pick);
    #  push @buttons, $button;
    #}
    {
      my $button = Gtk3::Button->new('Cleanup Memory Card');
      $button->signal_connect(clicked => sub { clean_memory_card($window) });
      push @buttons, $button;
    }
    {
      my $button = Gtk3::Button->new('Quit');
      $button->signal_connect(clicked => \&quit);
      push @buttons, $button;
    }

    my $cont = Gtk3::Box->new('vertical', 5);
    $cont->pack_start($_, TRUE, TRUE, 0) for @buttons; 
  
    $window->add($cont);
    $window->show_all;
  
    Gtk3::main;  
  }
  
  sub import_from_memory_card {
    clean_or_import(import => 1);
  }
  
  sub clean_memory_card {
    clean_or_import(clean => 1);
  }
  
  sub clean_or_import (%params) {
    my $clean  = $params{'clean'};
    my $import = $params{'import'};
    
    die 'Usage: clean_or_import("clean|import" => 1)'
      unless $clean xor $import;
    
    my $dial = Gtk3::Dialog->new('Scanning', $params{'parent'}, 'modal');
    my $hbox = Gtk3::Box->new('horizontal', 8);
    $hbox->set_border_width(8);
    
    my $text = Gtk3::Label->new;
    $text->set_text('Please wait... getting ready...');
    $hbox->add($text);  
    $dial->get_content_area->add($hbox);
    $dial->show_all;
    
    # Check for DCIM folders
    my @dcims = PIH::find_dcims();
    if (@dcims > 1) {
      $text->set_text("More than one digital camera memory card detected.\nPlease unplug or eject excess devices.");
      $dial->add_button('OK', 1);
      $dial->signal_connect(response => sub { $dial->destroy; });
      return;
    } elsif (@dcims == 0) {
      $text->set_text("Could not find a digital camera memory card.\nPlease connect your device and try again.");
      $dial->add_button('OK', 1);
      $dial->signal_connect(response => sub { $dial->destroy; });
      return;
    }
            
    my $last_message;
    my $fork = fork;    
    if (defined $fork and $fork == 0) {
      # In Child Process
      my $message_printer = sub ($status, $message, @slurp) { 
        PIH::put_ipc_message({ status => $status, user_message => $message, @slurp });
      };
      
      $message_printer->('WORKING', 'Scanning memory card');
      PIH::index_files('remote', sub {
        my $sub_message = shift || '';
        $sub_message .= '...';
        $message_printer->('WORKING', 'Scanning memory card ' . $sub_message);
      });
      sleep 1;
      
      if (PIH::remote_files_count() == 0) {
        $message_printer->('DONE', 'Done.');
        exit;
      }        
      
      $message_printer->('WORKING', 'Scanning computer');
      PIH::index_files('local',  sub {
        my $sub_message = shift || '';
        $sub_message .= '...';
        $message_printer->('WORKING', 'Scanning computer ' . $sub_message);
      });
      sleep 1;

      $message_printer->('WORKING', 'Analyzing...');
      my $data;   
      if ($clean) {
        $data = { remote_files_on_local => [PIH::remote_files_on_local()] };
      } elsif ($import) {
        $data = { remote_files_not_on_local => [PIH::remote_files_not_on_local()] };
      }
      sleep 1;
      
      # Done
      $message_printer->('DONE', 'Done.', data => $data);
      exit;
    } else {
      # parent
      Glib::Timeout->add(500, sub {
        my @messages = PIH::get_ipc_messages();
        if (@messages) {
          my $message = pop @messages;
          $last_message = $message;
          $text->set_text($message->{'user_message'});
          if ($message->{'status'} eq 'DONE') {

            # Special case - no files on memory card
            my $remote_files_count = PIH::remote_files_count();
            if ($remote_files_count == 0) {
              $text->set_text("No photos on memory card found.");
              $dial->add_button('OK', 1);
              $dial->signal_connect(response => sub { $dial->destroy; });
              return TIMEOUT_FINISH;
            }         

            if ($clean) {
              # Special case - no duplicates
              my $duplicate_count = $last_message->{'data'}{'remote_files_on_local'}->@*;
              if ($duplicate_count == 0) {
                $text->set_text("No duplicate photos found.");
                $dial->add_button('OK', 1);
                $dial->signal_connect(response => sub { $dial->destroy; });
                return TIMEOUT_FINISH;
              }
            
              # Advise user and get response
              $text->set_text("There are $remote_files_count photos on your memory card.\n"
                . "Of these, $duplicate_count exist on your computer.\n"
                . "Shall I delete the $duplicate_count duplicates from your memory card?"
              );
              $dial->add_button('Cancel', 0);
              $dial->add_button('Delete Them', 1);
              $dial->show_all;
              $dial->signal_connect(response => sub ($dial_copy, $response_ok, @slurp) {
                $dial->destroy;
                cleanup_memory_card_continue(
                  #window => $window,
                  files => $message->{data}{remote_files_on_local},
                ) if $response_ok;
              });
              return TIMEOUT_FINISH;
            } elsif ($import) {
              # Are all of the photos imported already?
              $dial->destroy;
              import_from_memory_card_continue(
                #window => $window,
                files => $message->{data}{remote_files_not_on_local},
              );
              return TIMEOUT_FINISH;
            }
          }
        }
        return TIMEOUT_REPEAT;
      });
    }
  }
  
  sub import_from_memory_card_continue (%params) {
    my $file_list = $params{'files'};   
    my $count     = scalar @$file_list;
    
    show_dialog(
      title   => 'Import from Memory Card',
      message => "Found $count files on memory card that have not been imported yet.",
      cancel  => sub ($dial, @) { $dial->destroy(); },
      buttons => [
        { label   => 'Import All',
          action => sub ($dial, @) {
            ...
          },
        },
        { label   => 'Pick & Choose',
          action => sub ($dial, @) {
            $dial->destroy;
            import_from_memory_card_pick_and_choose(files => $file_list);
          }
        },
      ],
    );
  }

=crap
  sub import_from_memory_card_continue_old (%params) {
    my $file_list = $params{'files'};   
    my $count     = scalar @$file_list;
    
    my $dial = Gtk3::Dialog->new('Import from Memory Card', $params{'parent'}, 'modal');
    my $hbox = Gtk3::Box->new('horizontal', 8);
    $hbox->set_border_width(8);
    
    my $text = Gtk3::Label->new;
    $text->set_text("Found $count files on memory card that have not been imported yet.");
    $hbox->add($text);
    
    $dial->add_button('Cancel', 0);
    $dial->add_button('Import All', 1);
    $dial->add_button('Pick & Choose', 2);
    $dial->show_all;
    $dial->signal_connect(response => sub ($dial_copy, $response, @slurp) {
      $dial->destroy;
      if ($response == 1) {
        #import_from_memory_card_all(files => $file_list);
      } elsif ($response == 2) {
        import_from_memory_card_pick_and_choose(files => $file_list);
      }
    });
    $dial->get_content_area->add($hbox);
    $dial->show_all;
  }
=cut
  
  sub import_from_memory_card_pick_and_choose (%params) {
    return import_from_memory_card_scrollwindow(%params);
    my $file_list = $params{'files'};
    
    # Make window
    my $window = Gtk3::Window->new;
    $window->set_default_size(800*.9,600*.9);
    
    my $vbox = Gtk3::Box->new('vertical', 8);
    $vbox->set_border_width(8);
    #$vbox->set_default_size(700,500);
    
    # Make image
    # my $view   = Gtk3::ImageView->new;
    my $pixbuf = Gtk3::Gdk::Pixbuf->new_from_file($file_list->[0]);
    my $thumb  = $pixbuf->scale_simple(640, 480, 'bilinear');
    my $image  = Gtk3::Image->new_from_pixbuf($thumb);
    #$view->set_pixbuf($pixbuf, TRUE);
    #$view->set_zoom(20);
    $vbox->add($image);

    # Make buttons
    my $hbox = Gtk3::Box->new('horizontal', 8);
    $hbox->pack_start( Gtk3::Button->new('Back'         ), TRUE, TRUE, 20);
    $hbox->pack_start( Gtk3::Button->new('Import (Move)'), TRUE, TRUE,  0);
    $hbox->pack_start( Gtk3::Button->new('Import (Copy)'), TRUE, TRUE,  0);
    $hbox->pack_start( Gtk3::Button->new('Erase'        ), TRUE, TRUE,  0);
    $hbox->pack_start( Gtk3::Button->new('SKip'         ), TRUE, TRUE, 20);
    $vbox->add($hbox);
    
    $window->add($vbox);
    $window->show_all;
  }
  
  sub import_from_memory_card_scrollwindow (%params) {
    my $file_list = $params{'files'};
   
    my $window=Gtk3::Window->new('toplevel');
    $window->set_title('Pick & Choose from Memory Card');
    $window->set_default_size(800*0.9,600*0.9);
   
    # the scrolled window
    my $scrolled_window = Gtk3::ScrolledWindow->new();
    $scrolled_window->set_border_width(10);

    # there is always the scrollbar (otherwise: automatic - only if needed - or never
    $scrolled_window->set_policy('automatic', 'always');

    my $vbox_outer = Gtk3::Box->new('vertical', 8);
    my $vbox = Gtk3::Box->new('vertical', 8);
    $vbox->set_border_width(8);
    
    my $blank_image_pixbuf = Gtk3::Gdk::Pixbuf->new('rgb', FALSE, 8, 640/4, 480/4);
    $blank_image_pixbuf->fill(0xAAAAAAAA);
  
    my $movie_image_pixbuf = eval {
      Gtk3::Gdk::Pixbuf
        ->new_from_file("$FindBin::Bin/../icon/movie_reel.png")
        ->scale_simple(640/4, 480/4, 'bilinear');
    } or $blank_image_pixbuf;
     
    my $checkboxes = [];
    my $toggle_checkbox = sub ($id, $type) {
      $checkboxes->[$id]{$type} = !$checkboxes->[$id]{$type};
    };
    
    my @images = ();
    {
      my $i = 0; 
      while ($i <= $#$file_list) {
        my $hbox = Gtk3::Box->new('horizontal', 8);
        for (1..4) {
          next if $i > $#$file_list;
          my $vbox_inner = Gtk3::Box->new('vertical', 2);
          
          # Checkboxes
          my $hbox_inner = Gtk3::Box->new('horizontal', 2);
          foreach my $cb (qw|Import Remove|) {
            my $check = Gtk3::CheckButton->new;
            my $my_i = $i;
            $check->set_label($cb);
            $check->signal_connect('toggled' => sub { $toggle_checkbox->($my_i, $cb) });
            $hbox_inner->add($check);
          }
          push @$checkboxes, { Import => 0, Remove => 0 };
          
          #my $pixbuf = Gtk3::Gdk::Pixbuf->new_from_file($file_list->[$i]);
          #my $thumb  = $pixbuf->scale_simple(640/4, 480/4, 'bilinear');
          my $image  = Gtk3::Image->new_from_pixbuf($blank_image_pixbuf);
          #my $image  = Gtk3::Image->new_from_gicon('broken', 640/4, 480/4);
          
          my $filename = $file_list->[$i];
          my $image_eventbox = Gtk3::EventBox->new;
          $image_eventbox->add($image);
          $image_eventbox->signal_connect('button-press-event' => sub ($widget, $event) {
            system('open', $filename) if $event->type eq '2button-press';
          });
          $vbox_inner->add($image_eventbox);
          
          #$vbox_inner->add($image);
          $vbox_inner->add($hbox_inner);
          $hbox->add($vbox_inner);
          
          push @images, $image;
          $i++;
        }
        $vbox->add($hbox);
      }
    }
      
    # Add buttons
    my $action_button_hbox = Gtk3::Box->new('horizontal', 2);
    my $action_button_wait = Gtk3::Label->new('Loading, please wait...');
    my $button_can = Gtk3::Button->new('Cancel');
    my $button_pro = Gtk3::Button->new('Proceed');    

    # add the image to the scrolled window
    $scrolled_window->add_with_viewport($vbox);
    $scrolled_window->set_vexpand(1);
    
    # add the scrolled window to the window
    $vbox_outer->add($scrolled_window);
    $window->add($vbox_outer);
    
    $vbox_outer->add($action_button_wait);   
    my $add_buttons = sub {
      $action_button_wait->destroy;
      $action_button_hbox->pack_start($button_can, TRUE, TRUE, 0);
      $action_button_hbox->pack_start($button_pro, TRUE, TRUE, 0);
      $vbox_outer->add($action_button_hbox);
      $vbox_outer->show_all;
    };
    
    # add actions
    $button_can->signal_connect(clicked => sub { $window->destroy; });
    $button_pro->signal_connect(clicked => sub {
      my $summary = "Confirm the following action:";
      my %count   = (move => 0, copy => 0, lose => 0);
      foreach my $selection (@$checkboxes) {
        $count{lose}++ if !$selection->{Import} and  $selection->{Remove};
        $count{move}++ if  $selection->{Import} and  $selection->{Remove};
        $count{copy}++ if  $selection->{Import} and !$selection->{Remove};
      }
      $summary .= "\n - $count{copy} photos will be copied to your computer" if $count{copy};
      $summary .= "\n - $count{move} photos will be moved to your computer"  if $count{move};
      $summary .= "\n - $count{lose} photos will be deleted entirely and permanently lost!" if $count{lose};
      
      my $total_actions = $count{copy} + $count{move} + $count{lose};
      $summary = "No actions selected." if $total_actions == 0;
      
      my $dial = Gtk3::Dialog->new('Confirm', $window, 'modal');
      my $hbox = Gtk3::Box->new('horizontal', 8);
      $hbox->set_border_width(8);
      my $text = Gtk3::Label->new($summary);
      $hbox->add($text);
      $dial->get_content_area->add($hbox);
      $dial->add_button('Cancel', 0);
      $dial->add_button('Confirm', 1) if $total_actions > 0;
      $dial->signal_connect(response => sub ($mywindow, $myresponse, @slurp) {
        unless ($myresponse) {
          $dial->destroy;
          return;
        }
        import_from_memory_card_process(files => $file_list, actions => $checkboxes);
        $dial->destroy;
      });
      $dial->show_all();
    });

    # show window and start MainLoop
    $window->show_all();

    # Load photos
    my $i = 0;
    Glib::Timeout->add(100, sub {
      if ($file_list->[$i] !~ m/MOV|MP4$/i) {
        my $pixbuf = Gtk3::Gdk::Pixbuf->new_from_file($file_list->[$i]);
        my $thumb  = $pixbuf->scale_simple(640/4, 480/4, 'bilinear');
        $images[$i]->set_from_pixbuf($thumb);
      } else {
        $images[$i]->set_from_pixbuf($movie_image_pixbuf);
      }
      $i++;
      if ($i > $#$file_list) {
        $add_buttons->();
        return TIMEOUT_FINISH;
      } else {
        return TIMEOUT_REPEAT;
      }
    });
  }
  
  sub import_from_memory_card_process (%params) {
    my $file_list = $params{'files'};
    my $actions   = $params{'actions'};

    my $dial = Gtk3::Dialog->new('Processing', undef, 'modal');
    my $hbox = Gtk3::Box->new('horizontal', 8);
    $hbox->set_border_width(8);
    my $text = Gtk3::Label->new('Preparing');
    $hbox->add($text);
    $dial->get_content_area->add($hbox);
    $dial->show_all;

    my $fork = fork;
    die 'Unable to fork!' unless defined $fork;

    if ($fork == 0) {
      # child
      my @action_list = ();
    
      for my $i (0 .. $#$file_list) {
        if ($actions->[$i]{Import}) {
          push @action_list, sub { PIH::import_file($file_list->[$i]) };
        }
        if ($actions->[$i]{Remove}) {
          push @action_list, sub { PIH::delete_file($file_list->[$i]) };
        }
      }
      
      for my $i (0 .. $#action_list) {
        my $action  = $action_list[$i];
        $action->();
        PIH::put_ipc_message({ status => 'WORKING', user_message => $i+1 . ' of ' . @action_list });
      }
      PIH::put_ipc_message({ status => 'DONE' });
      exit 0;
    }
    
    Glib::Timeout->add(500, sub {
      my @messages = PIH::get_ipc_messages();
      if (my $message = pop @messages) {
        if ($message->{status} eq 'DONE') {
          $dial->destroy();
          return TIMEOUT_FINISH;
        } elsif ($message->{status} eq 'WORKING') {
          $text->set_text($message->{user_message});
        }
      }
      return TIMEOUT_REPEAT;
    });
  }
   
  sub cleanup_memory_card_continue (%params) {
    my $file_list = $params{'files'};

    my $dial = Gtk3::Dialog->new('Memory Card Cleanup', $params{'parent'}, 'modal');
    my $hbox = Gtk3::Box->new('horizontal', 8);
    $hbox->set_border_width(8);
    
    my $text = Gtk3::Label->new;
    $text->set_text('Removing duplicates from memory card...');
    $hbox->add($text);  
    $dial->get_content_area->add($hbox);
    $dial->show_all;

    my $fork = fork;    
    if (defined $fork and $fork == 0) {
      # In Child Process
      my $message_printer = \&PIH::put_ipc_message;
      $message_printer->({ status => 'WORKING'});
      
      foreach my $file (@$file_list) {
        warn "Simulating delete of $file";
        sleep 1;
      }
      
      $message_printer->({ status => 'DONE' });
      exit;
    } else {
      Glib::Timeout->add(500, sub {
        my @messages = PIH::get_ipc_messages();
        if (@messages) {
          my $message = pop @messages;
          #$last_message = $message;
          if ($message->{'status'} eq 'DONE') {
            $text->set_text('Finished.');
            $dial->add_button('OK', 0);
            $dial->show_all;
            $dial->signal_connect(response => sub { $dial->destroy; });
            return TIMEOUT_FINISH;
          } elsif ($message->{'status'} eq 'ERROR') {
            $text->set_text('An error occurred.');
            $dial->add_button('OK', 0);
            $dial->show_all;
            $dial->signal_connect(response => sub { $dial->destroy; });
            return TIMEOUT_FINISH;
          }
        }
        
        unless (kill IS_RUNNING, $fork) {
          select(undef, undef, undef, 0.25);
          return TIMEOUT_REPEAT if PIH::get_ipc_messages();
          
          $text->set_text('An unknown error occurred.');
          $dial->add_button('OK');
          $dial->show_all;
          $dial->signal_connect(response => sub { $dial->destroy; });
          return TIMEOUT_FINISH;
        }
        
        return TIMEOUT_REPEAT;
      });
    }
  }
  
  sub quit {
    Gtk3::main_quit;
    exit 0;
  }
}

1;
