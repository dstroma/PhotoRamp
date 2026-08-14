requires 'perl', 'v5.26';

requires 'DateTime';
requires 'DBI';
requires 'DBD::SQLite';
requires 'Digest::MD5';
requires 'File::Copy';
requires 'File::Find::Rule';
requires 'File::Spec';
requires 'File::Temp';
requires 'Image::ExifTool';
requires 'JSON::MaybeXS';
requires 'MIME::Base64';
requires 'Gzip::Libdeflate';

# Technically only required for perl < 5.44
requires 'Sublike::Extended', '0.29';

recommends 'Cpanel::JSON::XS';

on 'test' => sub {
    requires 'Test::More', '0.98';
};

