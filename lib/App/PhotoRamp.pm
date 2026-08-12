use v5.34;
use experimental 'signatures';
package App::PhotoRamp 0.01 {
  use File::Find::Rule;
  use File::Spec;
  use File::Temp;
  use Digest::MD5;
  use DBI;
  use DBD::SQLite;
  use JSON::MaybeXS;
  use Fcntl ':seek';
  use autodie;

  use constant WINDOWS_OS =>
    (eval "use Win32; 1" ? 1 : 0);

  use constant FILE_EXTENSIONS =>
    'jpg|jpeg|tiff|tif|raw|gif|png|psd|heif|heic|webp|bmp|svg|eps|ai|avi|mp4|mpg|mov|mkv|wmv|webm|flv|3gp';

  my $FILE_EXTENSIONS    = FILE_EXTENSIONS;
  my $username           = get_username();
  my $remote_photos_dir;
  my $local_photos_dir   = get_user_pictures_dir();
  my $temp_dir           = File::Temp->newdir();

  setup_db();

  #####################################################################

  sub get_username {
    eval { getlogin() } // eval { scalar getpwuid($<) } // $ENV{LOGNAME} // $ENV{USER} // undef;
  }

  sub get_user_pictures_dir {
    my $dir;

    if (WINDOWS_OS) {
      return $dir if defined ($dir = Win32::GetFolderPath(Win32::CSIDL_MYPICTURES));
      return $dir if $username and -d ($dir = "C:\Users\$username\Pictures");
      return $dir if $username and -d ($dir = "C:\Documents and Settings\$username\My Pictures");
      return $dir if $username and -d ($dir = "C:\Documents\$username\My Pictures");
      return $dir if -d ($dir = "C:\My Documents\My Pictures");

      die "Unable to determine My Pictures directory (Windows).\n";
    }

    return $dir if defined $ENV{HOME} and -d ($dir = "$ENV{HOME}/Pictures");
    return $dir if defined $ENV{HOME} and -d ($dir = "$ENV{HOME}/pictures");
    return $dir if $username and -d ($dir = "/home/$username/Pictures");
    return $dir if $username and -d ($dir = "/home/$username/pictures");
    return $dir if $username and -d ($dir = "/Users/$username/Pictures");
    return $dir if $username and -d ($dir = "/Users/$username/pictures");

    die "Unable to determine My Pictures directory (non-Windows).\n";
  }

  sub debug_local_photos_dir {
    $local_photos_dir;
  }

  sub debug_remote_photos_dir {
    return $remote_photos_dir if $remote_photos_dir;
    my @dcims = find_dcims();
    warn "multiple digical camera devices!" if @dcims > 1;
    return $dcims[0];
  }

  sub catfile               (@parts)  { File::Spec->catfile(@parts);  }
  sub set_local_photos_dir  ($newdir) { $local_photos_dir  = $newdir; }
  sub set_remote_photos_dir ($newdir) { $remote_photos_dir = $newdir; }
  sub get_last_char                   { substr($_[0], -1, 1) }
  sub my_unlink ($filename) {
    warn "Deleting $filename";
    unlink $filename;
  }

  sub oldest_time ($file) {
    my @stat = stat($file);
    @stat = sort { $a <=> $b } @stat[8,9,10]; #8-atime, 9-mtime, 10-ctime
    my $oldest_time = $stat[0];
  }

  my $dbh;
  sub setup_db {
    return if $dbh;

    my $dbfile = catfile($temp_dir, 'photoramp.db');
    warn "Database file will be located at $dbfile";
    rename($dbfile => "$dbfile.old") if -e $dbfile;
    $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile",'','');
    setup_db_table_remote_photos();
    setup_db_table_local_photos();
    setup_db_table_ipc();
  }

  sub setup_db_table_remote_photos {
    $dbh->do('DROP TABLE IF EXISTS remote_photos');
    $dbh->do('
      CREATE TABLE remote_photos (
        id          integer     PRIMARY KEY,
        filename    text        UNIQUE,
        size        integer,
        md5_b64     text,
        md5_b64_spl text,
        on_local    boolean     DEFAULT 0,
        local_copy  text        DEFAULT NULL
      );
    ');
    $dbh->do('CREATE INDEX remote_photos_size_index ON remote_photos (size)');
  }

  sub setup_db_table_local_photos {
    $dbh->do('DROP TABLE IF EXISTS local_photos');
    $dbh->do('
      CREATE TABLE local_photos (
        id          integer     PRIMARY KEY,
        filename    text        UNIQUE,
        size        integer,
        md5_b64     text,
        md5_b64_spl text
      );
    ');
    $dbh->do('CREATE INDEX local_photos_size_index ON local_photos (size)');
  }

  sub setup_db_table_ipc {
    $dbh->do('
      -- Interprocess Communication
      CREATE TABLE ipc (
        id         integer PRIMARY KEY,
        process_id integer,
        message    text,
        read       boolean default FALSE
      );
    ');
  }

  sub get_ipc_messages {
    state $sth_select = $dbh->prepare('SELECT id, message FROM ipc WHERE read = false ORDER BY id ASC');
    state $sth_update = $dbh->prepare('UPDATE ipc SET read = TRUE where id = ?');

    $sth_select->execute();
    my @messages;
    while (my ($new_id, $new_message) = $sth_select->fetchrow_array) {
      push @messages, decode_json($new_message);
      $sth_update->execute($new_id);
    }
    return @messages;
  }

  sub put_ipc_message ($message) {
    state $sth_insert = $dbh->prepare('INSERT INTO ipc (process_id, message, read) VALUES (?,?,false)');
    $message = encode_json($message) if ref $message;
    $sth_insert->execute($$, $message);
    return 1;
  }

  sub verify_files_identical ($file1, $file2) {
    my $buf1;
    my $buf2;
    open my $fh1, '<', $file1;
    open my $fh2, '<', $file2;
    binmode $fh1;
    binmode $fh2;
    my $bytes1;
    my $bytes2;
    while ($bytes1 = read($fh1, $buf1, 1024) and $bytes2 = read($fh2, $buf2, 1024)) {
      next if $bytes1 and $bytes2 and $buf1 eq $buf2;
      close $fh1;
      close $fh2;
      return undef;
    }

    # Sanity check
    unless (-s $file1 == -s $file2) {
      warn 'Files are identical but have different sizes!';
      return undef;
    }

    return 1;
  }

  sub copy_file ($file1, $file2) {
    # Check files
    unless (-e $file1) {
      die "Origin file does not exist";
    }
    if (-e $file2) {
      die "Destination file already exists";
    }

    my $buf1;
    open my $fh1, '<', $file1;
    open my $fh2, '>', $file2;
    binmode $fh1;
    binmode $fh2;
    while (read($fh1, $buf1, 1024)) {
      print $fh2 $buf1;
    }
    close $fh1;
    close $fh2;

    my $oldest_time = oldest_time($file1);
    utime $oldest_time, $oldest_time, $file2;
    return 1;
  }

  sub index_files ($where, $callback = undef) {
    my $dir;
    if ($where eq 'remote') {
      my @dcims = find_dcims() or die "No camera devices or media cards found.\n";
      die 'Found multiple drives' unless @dcims == 1;
      $dir = $dcims[0];
    } elsif ($where eq 'local') {
      $dir = $local_photos_dir;
    } else {
      die '$where should be local or remote'
    }

    eval 'setup_db_table_'.$where.'_photos()';

    # Index files
    my $table = $where . '_photos';
    my @files = File::Find::Rule
      ->file
      ->nonempty
      ->name(qr/^[^\.].+\.($FILE_EXTENSIONS)$/i)
      ->in($dir);

    my $count = scalar @files;
    my $cur   = 1;
    $dbh->do("DELETE FROM $table");
    my $sth = $dbh->prepare("INSERT INTO $table (filename, size) VALUES (?,?)");
    foreach my $file (@files) {
      $callback->("$cur of $count")
        if $callback and ref $callback and (
          $cur == 0 or $cur == $count or $cur % 20 == 0
        ); # don't flood
      $sth->execute($file, -s $file);
      $cur++;
    }
    $sth->finish;

    return scalar @files || -1;
  }

  sub base_to_digest_method_name ($base) {
    return 'b64digest' if $base == 64;
    return 'hexdigest' if $base == 16;
    return 'digest'    if $base ==  2;
    die 'Unsupported base for Digest::MD5: ' . $base;
  };

  sub md5_file ($filename, $base = 64) {
    my $md5_method = base_to_digest_method_name($base);
    open my $fh, '<', $filename || die "Cannot open $filename!";
    binmode $fh;
    return Digest::MD5->new->addfile($fh)->$md5_method;
  }

  sub md5_file_sample ($filename, $base = 64) {
    my $md5_method = base_to_digest_method_name($base);
    my $md5 = Digest::MD5->new;
    open my $fh, '<', $filename || die "Cannot open $filename!";
    binmode $fh;
    my $buf;

    # Take 16 samples of 16KB each
    my $num_of_samples = 16;
    my $sample_size    = 16 * 1024;
    my $file_size      = -s $filename;
    my $step_size      = int $file_size / $num_of_samples;
    $step_size = 0 if $file_size <= $num_of_samples*$sample_size;

    while (read $fh, $buf, $sample_size) {
      $md5->add($buf);
      seek $fh, $step_size, SEEK_CUR if $step_size > 0;
    }

    return $md5->$md5_method;
  }

  sub find_dcims {
    return ($remote_photos_dir) if $remote_photos_dir;
    my $base;
    if (-d '/Volumes') {
      $base = '/Volumes';
    } elsif (-d '/media/'.$username) {
      $base = '/media/'.$username;
    } elsif (-d '/media') {
      $base = '/media';
    } else {
      warn "Cannot find any removable media in /Volumes or /media.";
      return;
    }
    my @dirs = File::Find::Rule->directory->name('DCIM')->maxdepth(3)->in($base);
    return @dirs;
  }

  sub duplicate_local_files {
    index_files('local');

    my @common_sizes = ();
    my $sth = $dbh->prepare('
      SELECT id, filename FROM local_photos
      WHERE size IN (
        SELECT size FROM local_photos
        GROUP BY size HAVING COUNT(*) > 1
      )
    ');
    $sth->execute;
    while (my ($id, $filename) = $sth->fetchrow_array) {
      my $md5 = md5_file($filename);
      $dbh->do('UPDATE local_photos SET md5_b64 = ? WHERE id = ? AND filename = ?', undef, $md5, $id, $filename);
    }
    $sth->finish;

    $sth = $dbh->prepare('
      SELECT id, filename, size, md5_b64 FROM local_photos
      WHERE md5_b64 IS NOT NULL AND md5_b64 IN (
        SELECT md5_b64 FROM local_photos
        WHERE md5_b64 IS NOT NULL
        GROUP BY md5_b64 HAVING COUNT(*) > 1
      )
      ORDER BY md5_b64, filename ASC
    ');
    $sth->execute;

    my @dups = ();
    while (my ($id, $filename, $size, $md5) = $sth->fetchrow_array) {
      push @dups, { id => $id, filename => $filename, size => $size, md5_b64 => $md5 };
    }

    return @dups;
  }

  sub remote_files_count {
    my ($count) = $dbh->selectrow_array('SELECT COUNT(1) FROM remote_photos');
    return $count;
  }

  sub remote_files {
    my $sth = $dbh->prepare(
      'SELECT filename FROM remote_photos ORDER BY filename ASC'
    );
    $sth->execute;
    my @files = ();
    while (my @row = $sth->fetchrow_array) {
      push @files, $row[0];
    }
    return @files;
  }

  sub remote_files_on_local {
    my $sth = $dbh->prepare('
      SELECT rem.id, rem.filename, loc.id, loc.filename
      FROM remote_photos AS rem, local_photos AS loc
      WHERE rem.size = loc.size
    ');
    $sth->execute;

    my @possible_dups = ();
    while (my @row = $sth->fetchrow_array) {
      push @possible_dups, \@row;
    }
    $sth->finish;

    # File sizes are duplicates, check md5s next
    my @duplicate_filenames;
    foreach my $row (@possible_dups) {
      my ($rem_id, $rem_fn, $loc_id, $loc_fn) = @$row;

      my $loc_md5 = md5_file_sample($loc_fn);
      my $rem_md5 = md5_file_sample($rem_fn);

      $dbh->do('UPDATE local_photos  SET md5_b64_spl = ? WHERE id = ?', undef, $loc_md5, $loc_id);
      $dbh->do('UPDATE remote_photos SET md5_b64_spl = ? WHERE id = ?', undef, $rem_md5, $rem_id);

      die 'Error!' unless length $loc_md5 and length $rem_md5;

      if ($loc_md5 eq $rem_md5) {
        push @duplicate_filenames, $rem_fn;
        $dbh->do('UPDATE remote_photos SET on_local = 1, local_copy = ? where id = ?', undef, $loc_fn, $rem_id);
      }
      # else {
      #  $dbh->do('UPDATE remote_photos SET on_local = 0 where id = ?', undef, $rem_id);
      #}
    }

    # If a local filename appears in the remote file list, there is a serious error!
    my ($oops) = $dbh->selectrow_array(
      'SELECT 1 FROM remote_photos WHERE filename IN (SELECT filename FROM local_photos) LIMIT 1'
    );
    if ($oops) {
      warn "A local file appears in the remote file list!";
      return;
    }

    return @duplicate_filenames;
  }

  sub verify_remote_file_has_local_copy ($remote_filename) {
    state $sth = $dbh->prepare(
      'SELECT local_copy FROM remote_photos WHERE filename = ? AND on_local LIMIT 1'
    );

    $sth->execute($remote_filename);
    my ($local_filename) = $sth->fetchrow_array;

    return verify_files_identical($remote_filename, $local_filename);
  }

  sub remote_files_not_on_local {
    # Search for non-duplicates
    # Best way to find non-duplicates is to first find duplicates
    remote_files_on_local();
    my $sth = $dbh->prepare('
      SELECT filename FROM remote_photos AS rem WHERE on_local = 0
    ');
    $sth->execute;

    my @filename_list = ();
    while (my ($filename) = $sth->fetchrow_array) {
      push @filename_list, $filename;
    }
    $sth->finish;

    return @filename_list;
  }

  sub copy_new_remote_photos_to_local (%params) {
    my $path   = $params{'path'};
    my $rename = $params{'rename'};
    my $delete = $params{'delete'};

    if ($delete) {
      die 'invalid delete param' unless $delete eq 'delete' or $delete eq 'trash';
    }

    my @new_files = remote_files_not_on_local();

    foreach my $file (@new_files) {
      my $new_file = undef;

      # copy
      copy_file($file, $new_file)
        or die 'Cannot copy file!';

      # Verify
      verify_identical($file, $new_file)
        or die 'Cannot verify file!';

      # delete?
    }
  }

  sub delete_file (%params) {
    my $filename = $params{'filename'};
    my $ok = my_unlink($filename);
    return $ok;
  }

  sub import_file ($from, $to = undef) {
    $to //= "$local_photos_dir/";

    die 'Usage: import_file($from_filename, $to_path_or_filename)'
      unless length $from and length $to;

    $to = new_filename_for_file($from, $to)
      if get_last_char($to) eq '/';

    die "File $to already exists!"
      if -e $to;

    # Copy and verify
    copy_file($from => $to);
    die "File became corrupted during copy"
      unless md5_file($from) eq md5_file($to);

    1;
  }

  sub new_filename_for_file ($existing, $dest_dir, $make_dir = 1) {
    # Clean
    chop $dest_dir if get_last_char($dest_dir) eq '/';

    # Get file time
    # Note the camera does not store time zone, so use gmtime() not localtime()
    my $otime = oldest_time($existing);
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($otime);

    # Fix numbers/zero pad
    $mon++;
    $year+= 1900;
    ($mon, $mday, $hour, $min) = map { sprintf('%02d', $_) } ($mon, $mday, $hour, $min);

    # Extension
    my ($extension) = $existing =~ m/\.(.+)$/;
    $extension //= '';

    # Subdir
    my $sub_dir = $year;

    # Base name
    my $base_name = "$year$mon$mday\_$hour$min";
    my $fq_filename;

    my $i = 0;
    do {
      $fq_filename = "$dest_dir/$sub_dir/$base_name\_$i.$extension";
      $i++;
    } while (-e $fq_filename);

    mkdir "$dest_dir/$sub_dir"
      if $make_dir and not -d "$dest_dir/$sub_dir";

    return $fq_filename;
  }

  sub exif_datetime_for_file ($filename) {
    require Image::ExifTool;
    require DateTime;
    state $exifTool = Image::ExifTool->new;

    my $info = $exifTool->ImageInfo($filename);
    my %info = %$info;
    my @alldates  =
      sort { $a cmp $b }
      grep { defined $_ }
      @info{qw/DateTimeOriginal DateTime DateTimeDigitized CreateDate FileInodeChangeDate FileModifyDate/};

    my $date = $alldates[0];
    return undef unless $date and length $date > 8;

    my ($Y, $M, $D, $h, $m, $s, $z) = $date =~ m/^(\d\d\d\d)\D(\d\d)\D(\d\d)\D(\d\d):(\d\d):(\d\d)(.*)$/;
    return DateTime->new(year => $Y, month => $M, day => $D, hour => $h, minute => $m, second => $s);
  }

  sub file_mime_type ($filename) {
    my ($ext)     = $filename =~ m/(\.[^\.]+)$/;
    my $mime_type = Plack::MIME->mime_type(lc $ext);
  }

  sub file_is_image ($fn) { file_mime_type($fn) =~ m/^image/; }
  sub file_is_video ($fn) { file_mime_type($fn) =~ m/^video/; }
  sub file_is_audio ($fn) { file_mime_type($fn) =~ m/^audio/; }
}

1;

__END__

=encoding utf-8

=head1 NAME

App::PhotoRamp - It's new $module

=head1 SYNOPSIS

    use App::PhotoRamp;

=head1 DESCRIPTION

App::PhotoRamp is ...

=head1 LICENSE

Copyright (C) Dondi Michael Stroma.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Dondi Michael Stroma E<lt>dstroma@gmail.comE<gt>

=cut

