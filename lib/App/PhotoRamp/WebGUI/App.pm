use v5.26;
use warnings;
use strict;
use experimental 'signatures';

package App::PhotoRamp::WebGUI::App 0.01 {
  use PlackX::Framework qw(Template);
  use App::PhotoRamp::WebGUI::App::Template {INCLUDE_PATH => "$ENV{PHOTORAMP_BASEDIR}/template"};
  use App::PhotoRamp::WebGUI::App::Router;
  use App::PhotoRamp;
  use App::PhotoRamp::Util qw(:all);

  use DateTime ();
  use File::Spec::Functions qw(catfile catdir);
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
  use App::PhotoRamp::WebGUI::Plack::Middleware::Static;
  use Plack::Middleware::AccessLog;
  sub apply_middleware ($app) {
    $app = App::PhotoRamp::WebGUI::Plack::Middleware::Static->wrap($app,
      path => sub { $_ =~ m`/static/$master_pid(/.+)$`; $_ = $1; return length $_ ? !!1 : !!0; },
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
    # Add a convenience hash key to env
    my $is_fast =
    $response->stash->{'fast_server'} = !!1
      if $request->{env}{'psgi.multiprocess'}
      or $request->{env}{'psgi.multithread'}
      or $request->{env}{'psgi.nonblocking'};
    $response->stash->{'slow_server'} = !$is_fast;

    # Template
    $response->stash->{'shutdown_url'} = "/shutdown?server_pid=$master_pid";

    # Just in case the accesslog middleware doesn't work
    my $t = time;
    utime $t, $t, $server_logfile;
    return $response->next;
  };

  route '/check-alive' => { text => 'OK' };

  # User routes
  route '/' => sub ($request, $response) {
    #$response->template->set(error_dialog => "Welcome");
    $response->template->set(show_shutdown_link => 1);
    return $response->render_template('main.phtml');
  };


  route '/get-messages/server-{server_pid}' => sub ($request, $response) {
    my $rpid = $request->route_param('server_pid');
    unless ($rpid eq $master_pid) {
      return $response->render_json({ server_pid => $master_pid });
    }

    my $last_id;
    if (my $cookie = $request->cookies->{"last_sent_message_id-$master_pid"}) {
      ($last_id) = $cookie =~ m/^\D*(\d+)\D*$/;
    }
    if (my $cookie = $request->cookies->{"last_read_message_id-$master_pid"}) {
      ($last_id) = $cookie =~ m/^\D*(\d+)\D*$/;
    }

    my @messages = App::PhotoRamp::get_ipc_messages($last_id ? $last_id : ());

    $response->cookies->{"last_sent_message_id-$master_pid"} = {
      'value'   => $messages[-1]->{id},
      'max-age' => 60*60*24,
    } if @messages;

    # Delete stale cookies
    my @cookienames = keys $request->cookies->%*;
    foreach my $name (@cookienames) {
      next if $name =~ m/-$master_pid$/;
      $response->cookies->{$name} = { value => '', 'max-age' => 0 };
    }

    return $response->render_json({ messages => \@messages, server_pid => $master_pid });
  };


  route { get => '/{action:import|cleanup}' } => sub ($request, $response) {
    my $action = $request->route_param('action');
    my @dcims  = App::PhotoRamp::find_dcims();
    if (@dcims > 1) {
      $response->flash('More than one digital camera memory card detected. Please unplug or eject excess devices.');
      return $response->redirect('/');
    } elsif (@dcims == 0) {
      $response->flash('No digital camera memory cards detected. Please insert storage device and try again.');
      return $response->redirect('/');
    }

    App::PhotoRamp::launch_task_worker({
      'sub'  => 'index_remote_and_local',
      'args' => [
        dcim_path => $dcims[0], analyze => 1, status_updates => 1, done_args => [ goto_url => "/$action-preview" ]
      ]
    });
    return $response->render_template('work.phtml');
  };


  route { get => '/{action:import|cleanup}-preview' } => sub ($request, $response) {
    my $action = $request->route_param('action');
    my $tmplt  = $response->template;

    $tmplt->set(remote_files_count         => App::PhotoRamp::remote_files_count());
    $tmplt->set(remote_files_not_on_local  => [App::PhotoRamp::remote_files_not_on_local()])
      if $action eq 'import';
    $tmplt->set(remote_files_on_local      => [App::PhotoRamp::remote_files_on_local()])
      if $action eq 'cleanup';

    return $response->render_template("${action}-preview.phtml");
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

    my @tasks;
    my $task_count = scalar @cleanup_list;
    my $cur_task   = 0;
    foreach my $file (@cleanup_list) {
      my $pct = int(100*(++$cur_task)/$task_count);
      push @tasks,
        { 'sub' => 'delete_remote_file_if_have_copy', 'args' => [$file], },
        { 'sub' => 'put_ipc_message', 'args' => [{ status => 'WORKING', user_message => "Processing ($pct%)" }] };
    }
    {
      push @tasks,
        { 'sub' => 'put_ipc_message', 'args' => [{ status => 'DONE', user_message => "Done", goto_url => '/complete' }] };
    }

    App::PhotoRamp::launch_task_worker(@tasks);
    return $response->render_template('work.phtml');
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

    my $task_count = scalar @import_list + scalar @delete_list;
    my $cur_task   = 0;
    my @tasks;

    foreach my $file (@import_list) {
      my $pct = int(100*(++$cur_task)/$task_count);
      push @tasks, (
        { 'sub' => 'import_file', 'args' => [$file], },
        { 'sub' => 'put_ipc_message', 'args' => [{ status => 'WORKING', user_message => "Processing ($pct%)" }] }
      );
    }
    foreach my $file (@delete_list) {
      my $pct = int(100*(++$cur_task)/$task_count);
      push @tasks, (
        { 'sub' => 'delete_file', 'args' => [$file], },
        { 'sub' => 'put_ipc_message', 'args' => [{ status => 'WORKING', user_message => "Processing ($pct%)" }] }
      );
    }

    push @tasks,{ 'sub' => 'put_ipc_message', 'args' => [{ status => 'DONE', goto_url => '/complete' }] };

    App::PhotoRamp::launch_task_worker(\@tasks);
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


  route '/shutdown' => sub ($request, $response) {
    my $param_pid = $request->param('server_pid');
    unless ($param_pid and $param_pid == $master_pid) {
      $response->status(403);
      return $response->render_text('Not Authorized');
    }

    # Close the user's browser
    if (open my $fh, '<', catfile($App::PhotoRamp::appdata_dir, 'webgui-browser.pid')) {
      my $browser_pid = <$fh>;
      chomp $browser_pid;
      kill 'TERM', $browser_pid;
    }

    # Tell server to stop
    if ($request->env->{'psgix.harakiri'}) {
      $request->env->{'psgix.harakiri.commit'} = 1;
    }

    if ($request->env->{'psgi.multiprocess'}) {
      kill 'TERM', $master_pid;
    }

    $response->render_html(
      '<html><body style="text-align: center; font-family: Sans-Serif;">' .
      '<h1>Application Ended</h1><p>You may close this window.</p>' .
      '</body></html>'
    );
  };

  route '/user-file/:u64_filename' => sub ($request, $response) {
    my $filename  = decode_u64($request->route_param('u64_filename'));
    my $mime_type = App::PhotoRamp::file_mime_type($filename);

    $response->content_type($mime_type);
    $response->body(IO::File->new($filename, '<:raw'));
    return $response;
  };


  route '/user-open/:u64_filename' => sub ($request, $response) {
    my $filename  = decode_u64($request->route_param('u64_filename'));

    if (App::PhotoRamp::WINDOWS_OS) {
      system(1, 'start', '', $filename);
    } elsif ($^O =~ m/darwin/) {
      system('open', $filename);
    } else {
      system('xdg-open', $filename);
    }

    return $response->render_text('OK');
  };


  route '/debug' => sub ($request, $response) {
    require Data::Dumper;
    return $response->render_text(Data::Dumper::Dumper({ request => $request, response => $response }));
  };
}

package App::PhotoRamp::WebGUI::App::Template {
  our $master_pid = $$;
  sub set_defaults ($self) {
    $self->set(
      dcim_relative => sub ($name) { my ($rel) = $name =~ m`DCIM[\/](.+)$`; $rel },
      encode_u64    => \&App::PhotoRamp::Util::encode_u64,
      server_pid    => $master_pid,
      worker_pid    => sub { eval '$$' },
      file_is_image => \&App::PhotoRamp::file_is_image,
      file_is_video => \&App::PhotoRamp::file_is_video,
      file_is_audio => \&App::PhotoRamp::file_is_audio,
      static_link   => sub ($link) {
        $link = substr($link, 1) if substr($link, 0, 1) eq '/';
        return "/static/$master_pid/$link"
      },
    );
    $self;
  }
}

1;
