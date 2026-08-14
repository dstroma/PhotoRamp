use v5.36;
package App::PhotoRamp::Journal {
  use App::PhotoRamp::Signatures;
  use DBI qw(:sql_types);
  use DBD::SQLite;
  use Image::ExifTool qw(ImageInfo);
  use JSON::MaybeXS qw(encode_json);
  use Gzip::Libdeflate ();

  our $APP        = "PhotoRamp" . (eval { $App::PhotoRamp::VERSION } // '');
  our $DB_VERSION = 1; # Increment upon schema changes! Only use integers.
  our $gzip       = Gzip::Libdeflate->new(level => 6);

  # Set up constants ##########################################################
  my @db_constants = qw(
    FALSE TRUE
    TEST
    LOCAL REMOTE
    COPY MOVE MODIFY DELETE
    NOWANT IMPORT
    REORGANIZE METACHANGE
    TIMESTAMPFIX
  );

  my %db_constants = map { $db_constants[$_] => $_ } 0 .. $#db_constants;

  sub constant { $db_constants{pop @_} // undef }

  die 'Incorrect constant value!' unless constant('FALSE') == 0;
  die 'Incorrect constant value!' unless constant('TRUE')  == 1;


  # OO Code ###################################################################
  sub new_or_open ($class, $dbfile) {
    my $self  = bless { dbfile => $dbfile }, $class;
    my $exist = -e $dbfile;
    my $dbh   = DBI->connect("dbi:SQLite:dbname=$dbfile",'','');

    die "Cannot create database handle for journal! $! " . DBI->errstr
      unless $dbh;

    $self->{dbh} = $dbh;
    $self->setup_db unless $exist;

    return $self;
  }

  sub dbh ($self) { $self->{dbh} }

  sub setup_db ($self) {
    $self->dbh->do(q{
      PRAGMA foreign_keys = ON
    }) or die "Cannot setup db!";

    $self->dbh->do(q{
      CREATE TABLE constants (
        id   integer PRIMARY KEY,
        name text UNIQUE
      ) STRICT
    }) or die "Cannot setup db!";

    $self->db_insert('constants', {
      id   => [$db_constants{$_}, SQL_INTEGER],
      name => $_
    }) for keys %db_constants;

    $self->dbh->do(q{
      CREATE TABLE file_info (
        id              integer  PRIMARY KEY,
        loctype         integer,
        filename        text,
        filestat        text,
        filesize        integer,
        filemd5_b64     text,
        exif_gzip       blob,
        exif_thumb      blob,
        FOREIGN KEY (loctype) REFERENCES constants(id)
      ) STRICT
    }) or die "Cannot setup db!";

    $self->dbh->do(q{
      CREATE TABLE journal_entries (
        id              integer  PRIMARY KEY,
        timestamp       text     DEFAULT CURRENT_TIMESTAMP,
        action          integer,
        successful      integer  DEFAULT NULL,
        reason          integer,
        app             text,
        user            text,
        org_file        integer,
        new_file        integer  DEFAULT NULL,
        FOREIGN KEY (successful) REFERENCES constants(id),
        FOREIGN KEY (action)     REFERENCES constants(id),
        FOREIGN KEY (reason)     REFERENCES constants(id),
        FOREIGN KEY (org_file)   REFERENCES file_info(id),
        FOREIGN KEY (new_file)   REFERENCES file_info(id)
      ) STRICT
    }) or die "Cannot setup db!";
  }

  sub log_action ($self, $from, $to = undef, :$action = undef, :$reason = undef) {
    die "Invalid action constant name '$action'"
      if defined $action and !defined constant($action);
    die "Invalid reason constant name '$reason'"
      if defined $reason and !defined constant($reason);

    my @files;
    foreach my $file (grep { defined $_ } ($from, $to)) {
      my @stat      = stat($file);
      my $exif      = ImageInfo($file);
      my $exif_gzip = eval { $gzip->compress(encode_json($exif)) };
      my $thumb     = $exif ? delete $exif->{ThumbnailImage} : undef; # stored as scalar ref

      my $loctype;
      $loctype = 'REMOTE' if $App::PhotoRamp::remote_photos_dir and $file =~ m/^$App::PhotoRamp::remote_photos_dir/;
      $loctype = 'LOCAL'  if $App::PhotoRamp::local_photos_dir  and $file =~ m/^$App::PhotoRamp::local_photos_dir/;

      # Note on thumbnails: only store thumbnails for TO file
      # This is both for privacy (in case user deletes a file) and disk space

      my %info;
      $info{loctype}    = constant($loctype) if $loctype;
      $info{filename}   = $file;
      $info{filestat}   = join(',',@stat) if @stat;
      $info{filesize}   = [ $stat[7]   , SQL_INTEGER ] if @stat;
      $info{exif_gzip}  = [ $exif_gzip , SQL_BLOB    ]
        if $exif_gzip;
      $info{exif_thumb} = [ $thumb->$* , SQL_BLOB    ]
        if (defined $to and $file eq $to) and $thumb and ref $thumb;

      $self->db_insert('file_info', \%info);
      $info{id} = $self->db_last_id('file_info');

      push @files, \%info;
    };

    die 'This should not happen, the @files array is empty'
      unless @files >= 1;

    $self->db_insert('journal_entries', {
      action   => defined $action ? constant($action) : undef,
      reason   => defined $reason ? constant($reason) : undef,
      app      => $APP,
      user     => $App::PhotoRamp::username // undef,
      org_file => $files[0]{id},
      new_file => $files[1] ? $files[1]{id} : undef,
    });

    return $self->db_last_id('journal_entries', 'id');
  }

  sub db_insert ($self, $table, $values) {
    die "Values must be hashref" unless ref $values eq 'HASH';

    my @keys = keys   %$values;
    my @vals = values %$values;
    my $stmt = sprintf(
      "INSERT INTO $table (%s) VALUES (%s)",
      join(',', @keys),
      join(',', ("?") x scalar(@keys)),
    );

    my $sth = $self->dbh->prepare_cached($stmt);
    foreach my $i (0 .. $#vals) {
      my @val  = ref $vals[$i] ? ($vals[$i]->@*) : ($vals[$i]);
      $sth->bind_param($i+1, @val);
    }
    $sth->execute() or die 'Cannot insert into journal! ' . $sth->errstr();
    $sth->finish();

    return 1;
  }

  sub set_action_status ($self, $id, :$success = undef, :$failure = undef) {
    die 'Must specify success=>1 or failure=>1' unless $success xor $failure;
    state $sth = $self->dbh->prepare("UPDATE journal_entries SET successful = ? WHERE id = ?");
    $sth->execute(($success ? constant('TRUE') : constant('FALSE')), $id);
  }

  sub db_last_id ($self, $table, $column = 'id') {
    $self->dbh->last_insert_id(undef, undef, $table, $column);
  }
}

1;
