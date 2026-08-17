use v5.26;
use warnings;
use strict;
use experimental 'signatures';

package App::PhotoRamp::WebGUI::App {
  use PlackX::Framework qw(Template);
  use App::PhotoRamp::WebGUI::App::Template {INCLUDE_PATH => "$ENV{PHOTORAMP_BASEDIR}/template"};
  use App::PhotoRamp::WebGUI::App::Router;
  use App::PhotoRamp;
  use App::PhotoRamp::Util qw(:all);

  use DateTime ();
  use IO::File ();
  use MIME::Base64 ();
  use Plack::MIME ();
  use POSIX qw(strftime);
  use Fcntl qw(:flock);

  use constant MINUTES       => 60;
  use constant MAX_IDLE_TIME => 1*MINUTES;

  our $master_pid = $$;

  # Set up logging
  my  $yearmo         = strftime('%Y%m', gmtime);
  our $server_logfile = catfile($App::PhotoRamp::appdata_dir, "webgui-server-$yearmo.log");
  my  $server_log_fh  = IO::File->new($server_logfile, '>>')
    or die "Cannot open $server_logfile! $!";

  $server_log_fh->print(sprintf("SERVER $$ STARTED at %s.\n\n", time));
  $server_log_fh->autoflush(1);
  open STDERR, '>&', $server_log_fh;

  rotate_logs();

  # Apply Middleware
  require Plack::Middleware::Static;
  use Plack::Middleware::AccessLog;
  sub apply_middleware ($app) {
    $app = Plack::Middleware::Static->wrap($app,
      path => qr//,
      root => "$ENV{PHOTORAMP_BASEDIR}/static/",
      pass_through => 1
    );
    $app = Plack::Middleware::AccessLog->wrap($app,
      logger => sub { $server_log_fh->print(@_) }
    );
    return $app;
  }

  sub rotate_logs {
    my $now  = DateTime->now->truncate(to => 'day');
    $now->set_day(14);

    # Gzip old logs
    {
      my $x = $now->clone;
      $x->subtract(months => 1);
      for (0..36) {
        my $xyearmo = $x->strftime('%Y%m');
        my $fname = catfile($App::PhotoRamp::appdata_dir, "webgui-server-$xyearmo.log");
        if (-e $fname) {
          warn "Gzipping old log $fname\n";
          gzip_file($fname, "$fname.gz");
          unlink $fname;
        }
        $x->subtract(months => 1);
      }
    }

    # Remove logs more than 1 year old
    {
      my $x = $now->clone;
      $x->subtract(years => 1);
      for (0..36) {
        my $xyearmo = $x->strftime('%Y%m');
        my $fname = catfile($App::PhotoRamp::appdata_dir, "webgui-server-$xyearmo.log.gz");
        if (-e $fname) {
          warn "Deleting old log $fname\n";
          unlink $fname;
        }
        $x->subtract(months => 1);
      }
    }
  }

  #############################################################################
  # Routes

  # Update activity time
  filter before => sub ($request, $response) {
    # Just in case the accesslog middleware doesn't work
    my $t = time;
    utime $t, $t, $server_logfile;
    return $response->next;
  };


  # User routes
  route '/' => sub ($request, $response) {
    #$response->template->set(error_dialog => "Welcome");
    return $response->render_template('main.phtml');
  };


  route '/get-messages/server-{server_pid}' => sub ($request, $response) {
    my $rpid = $request->route_param('server_pid');
    unless ($rpid eq $master_pid) {
      $response->status(500);
      $response->body("Error: Server master process ID is $master_pid, not $rpid!");
      return $response;
    }

    my $last_id;
    if (my $cook = $request->cookies->{"last_sent_message_id-$master_pid"}) {
      ($last_id) = $cook =~ m/^\D*(\d+)\D*$/;
    }
    if (my $cook = $request->cookies->{"last_read_message_id-$master_pid"}) {
      ($last_id) = $cook =~ m/^\D*(\d+)\D*$/;
    }

    my @messages = App::PhotoRamp::get_ipc_messages($last_id ? $last_id : ());

    $response->cookies->{"last_sent_message_id-$master_pid"} = {
      'value'   => $messages[-1]->{id},
      'max-age' => 60*60*24,
    } if @messages;

    return $response->render_json({ messages => \@messages, server_pid => $master_pid });
  };


  route '/check-alive' => sub ($request, $response) {
    return $response->render_text('OK');
  };


  route ['/{action:import|cleanup}'] => sub ($request, $response) {
    my @dcims = App::PhotoRamp::find_dcims();
    if (@dcims > 1) {
      $response->flash('More than one digital camera memory card detected. Please unplug or eject excess devices.');
      return $response->redirect('/');
    } elsif (@dcims == 0) {
      $response->flash('No digital camera memory cards detected. Please insert storage device and try again.');
      return $response->redirect('/');
    }

    my $last_message;
    my $fork = fork;
    if (defined $fork and $fork == 0) {
      $0 = 'PhotoRamp WebGUI Task Worker';

      # In Child Process
      my $message_printer = sub ($status, $message, @slurp) {
        App::PhotoRamp::put_ipc_message({ status => $status, user_message => $message, @slurp });
      };

      $message_printer->('WORKING', 'Scanning memory card');
      App::PhotoRamp::index_files('remote', sub {
        my $sub_message = shift || '';
        $sub_message .= '...';
        $message_printer->('WORKING', 'Scanning memory card ' . $sub_message);
      });
      sleep 1;

      if (App::PhotoRamp::remote_files_count() == 0) {
        $message_printer->('DONE', 'Done (no remote files found).');
        exit;
      }

      $message_printer->('WORKING', 'Scanning computer');
      App::PhotoRamp::index_files('local',  sub {
        my $sub_message = shift || '';
        $sub_message .= '...';
        $message_printer->('WORKING', 'Scanning computer ' . $sub_message);
      });
      sleep 1;

      $message_printer->('WORKING', 'Analyzing...');
      my $data;
      if (0) { #cleanup
        $data = { remote_files_on_local => [App::PhotoRamp::remote_files_on_local()] };
      } elsif (1) { #import
        $data = { remote_files_not_on_local => [App::PhotoRamp::remote_files_not_on_local()] };
      }
      sleep 1;

      # Done
      my $goto_url = $request->route_param('action') eq 'import' ?
        '/import-preview' :
        '/cleanup-confirm' ;

      $message_printer->('DONE', 'Done.', data => $data, goto_url => $goto_url);
      exit 0;
    }

    return $response->render_template('work.phtml');
  };


  route { get => '/cleanup-confirm' } => sub ($request, $response) {
    my $remote_files_count    = App::PhotoRamp::remote_files_count();
    my @remote_files_on_local = App::PhotoRamp::remote_files_on_local();

    $response->template->set(
      remote_files_count          => $remote_files_count,
      remote_files_on_local       => \@remote_files_on_local,
      remote_files_on_local_count => scalar @remote_files_on_local,
    );

    return $response->render_template('cleanup-confirm.phtml');
  };


  route { post => '/cleanup-submit' } => sub ($request, $response) {
    my $count_to_cleanup = $request->param('count_to_cleanup');
    my $parameters       = $request->parameters;
    my @cleanup_list;

    foreach my $key (keys %$parameters) {
      if ($key =~ m/^cleanup-(.+)$/) {
        my $filename_b64 = $1;
        push @cleanup_list, decode_u64($filename_b64)
          if $request->param($key);
      }
    }

    # Consistency check
    unless (@cleanup_list == $count_to_cleanup) {
      $response->flash('Error: cleanup count did not match cleanup file list. No actions taken.');
      $response->redirect('/');
    }

    my $fork = fork;
    if (defined $fork and $fork == 0) {
      my $tasks_total    = $count_to_cleanup;
      my $tasks_complete = 0;
      my $tasks_pct_done;

      App::PhotoRamp::put_ipc_message({ status => 'WORKING', user_message => "Processing (0%)..." });

      # Do the work
      foreach my $file (@cleanup_list) {
        # Triple check we are okay to delete!
        if (App::PhotoRamp::verify_remote_file_has_local_copy($file)) {
          App::PhotoRamp::delete_file(filename => $file);
        } else {
          warn "ERROR!";
        }
      }

      App::PhotoRamp::put_ipc_message({ status => 'DONE', goto_url => '/complete' });
    }

    return $response->render_template('work.phtml');
  };


  route '/import-preview' => sub ($request, $response) {
    my $remote_files_count        = App::PhotoRamp::remote_files_count();
    my @remote_files_not_on_local = App::PhotoRamp::remote_files_not_on_local();

    $response->template->set(
      remote_files_count        => $remote_files_count,
      remote_files_not_on_local => \@remote_files_not_on_local
    );

    return $response->render_template('import-preview.phtml');
  };


  route { post => '/import-submit' } => sub ($request, $response) {
    my $parameters = $request->parameters;

    my @import_list = ();
    my @delete_list = ();
    foreach my $key (keys %$parameters) {
      if ($key =~ m/^(import|delete)-(.+)$/) {
        my $action    = $1;
        my $fname_b64 = $2;
        push @import_list, decode_u64($fname_b64)
          if $action eq 'import' and $request->param($key) eq 'import';
        push @delete_list, decode_u64($fname_b64)
          if $action eq 'delete' and $request->param($key) eq 'delete';
      }
    }

    my $fork = fork();
    if (defined $fork and $fork == 0) {
      my $tasks = scalar @import_list + scalar @delete_list;
      my $prog  = 0;
      foreach my $file (@import_list) {
        my $pct = int($prog/$tasks * 100);
        App::PhotoRamp::import_file($file);
        App::PhotoRamp::put_ipc_message({ status => 'WORKING', user_message => "Processing ($pct%)..." });
        $prog++;
      }
      foreach my $file (@delete_list) {
        my $pct = int($prog/$tasks * 100);
        App::PhotoRamp::delete_file($file);
        App::PhotoRamp::put_ipc_message({ status => 'WORKING', user_message => "Processing ($pct%)..." });
        $prog++;
      }
      App::PhotoRamp::put_ipc_message({ status => 'DONE', user_message => "Processing (100%)...", goto_url => '/complete' });
      exit;
    }

    return $response->render_template('work.phtml');
  };


  route ['/fix-timestamps', '/timestamp-preview'] => sub ($request, $response) {
    my $sort = $request->param('sort_by');

    App::PhotoRamp::index_files('remote') unless App::PhotoRamp::remote_files_count() > 0;
    my @remote_files = App::PhotoRamp::remote_files();
    my @remote_details = ();

    foreach my $file (@remote_files) {
      # mtime = modified time
      # ctime = inode change time, on some filesystems, could be creation time
      #my $info     = $exifTool->ImageInfo($file);
      #my %info     = %$info;
      #my @exifdates = sort { $a cmp $b } grep { defined $_ } @info{qw/DateTimeOriginal DateTime DateTimeDigitized CreateDate/};
      #my @filedates = sort { $a cmp $b } grep { defined $_ } @info{qw/FileInodeChangeDate FileModifyDate/};
      #my @alldates  = sort { $a cmp $b } grep { defined $_ } @exifdates, @filedates;

      my ($shortname) = $file =~ m`DCIM[\/](.+)$`;
      push @remote_details, {
        filename        => $file,
        u64_filename    => encode_u64($file),
        shortname       => $shortname,
        #exif            => $info,
        #exif_timestamp  => $exifdates[0],
        #fsys_timestamp  => $filedates[0],
        #first_timestamp => $alldates[0],
        first_timestamp_dto => App::PhotoRamp::exif_datetime_for_file($file),
      };
    }

    @remote_details = sort { $a->{$sort} cmp $b->{$sort} } @remote_details if $sort;

    $response->template->set(
      remote_files_count        => scalar @remote_files,
      remote_files_with_details => \@remote_details,
    );

    return $response->render_template('timestamp-preview.phtml');
  };


  route '/fix-timestamps/get-shifted-times' => sub ($request, $response) {
    my $file_idx  = $request->param('file_idx');
    my $filename  = $request->param('filename');
    my $new_date  = $request->param('new_date');
    my $new_time  = $request->param('new_time');
    my $file_list = $request->param('file_list');
    my @file_list = map { decode_u64($_) } split /,/, $file_list;

    $filename = decode_u64($filename);
    my $dt_org = App::PhotoRamp::exif_datetime_for_file($filename);

    # Parse input date and time
    "$new_date $new_time" =~ m/^(\d\d\d\d)[\D](\d\d)[\D](\d\d)[\D](\d\d):(\d\d)/;
    my $dt_new = eval { DateTime->new(year => $1, month => $2, day => $3, hour => $4, minute => $5, second => 0) };
    return $response->render_json({ error_message => 'Please set a valid date and time to use the SHIFT feature.'})
      unless $dt_new;

    # Refuse to handle dates before 1970
    return $response->render_json({ error_message => 'Cannot use SHIFT feature with years before 1970.' })
      if $dt_org->year < 1970 or $dt_new->year < 1970;

    # Calculate delta
    my $delta = $dt_new->epoch - $dt_org->epoch;
    #my $delta_human = {};
    #$delta_human->{years} = int($delta  / (60*60*24*365.25));
    #$delta_human->{days}  = int(($delta - ($delta_human->{years}*60*60*24*365.25)) / (60*60*24));
    #$delta_human->{hours} = int(($delta - ($delta_human->{years}*60*60*24*365.25)  - ($delta_human->{days}*60*60*24)) / (60*60));
    #$delta_human->{summary} = ''
    #  . ($delta_human->{years} ? " $delta_human->{years} years" : '')
    #  . ($delta_human->{days}  ? " $delta_human->{days} days"   : '')
    #  . ($delta_human->{hours} ? " $delta_human->{hours} hours" : '');

    # Create a data structure with new timestamps
    # Start at idx+1
    my @data_out = ();
    for (my $i = $file_idx + 1; $i <= $#file_list; $i++) {
      my $dt = App::PhotoRamp::exif_datetime_for_file($file_list[$i]);
      $dt->add(seconds => $delta);
      push @data_out, { idx => $i, new_date => $dt->ymd, new_time => substr($dt->hms, 0, 5) };
    }

    return $response->render_json({ new_timestamps => \@data_out, delta => $delta }); # , delta_human => $delta_human });
  };


  route '/complete' => sub ($request, $response) {
    $response->flash('Tasks completed.');
    $response->redirect('/');
  };


  route '/user-file/:u64_filename' => sub ($request, $response) {
    my $filename  = decode_u64($request->route_param('u64_filename'));
    my $mime_type = App::PhotoRamp::file_mime_type($filename);

    $response->content_type($mime_type);
    $response->body(IO::File->new($filename, '<'));
    return $response;
  };


  route '/user-open/:u64_filename' => sub ($request, $response) {
    my $filename  = decode_u64($request->route_param('u64_filename'));

    if (fork() == 0) { `open "$filename"`; exit; }

    return $response->render_text('OK');
  };


  route '/debug' => sub ($request, $response) {
    require Data::Dumper;
    return $response->render_text(Data::Dumper::Dumper($request));
  };
}

package App::PhotoRamp::WebGUI::App::Template {
  our $master_pid = $$;
  sub set_defaults ($self) {
    $self->set(
      encode_u64    => \&App::PhotoRamp::Util::encode_u64,
      server_pid    => $master_pid,
      worker_pid    => sub { eval '$$' },
      file_is_image => \&App::PhotoRamp::file_is_image,
      file_is_video => \&App::PhotoRamp::file_is_video,
      file_is_audio => \&App::PhotoRamp::file_is_audio,
    );
    $self;
  }
}

1;
