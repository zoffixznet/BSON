#BEGIN { @*INC.unshift( 'lib' ) }

use v6;
use Test;
use BSON;
use BSON::ObjectId;

my %samples = (
  'ObjectId minimum' => {
    'str' => '000000000000000000000000',
    'buf' => [ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ],
  },

  'ObjectId maximum' => {
    'str' => 'ffffffffffffffffffffffff',
    'buf' => [ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff ],
  }
);

for %samples {
    is-deeply
        BSON::ObjectId.encode(.value{'str'}).perl,
        BSON::ObjectId.decode(Buf.new(.value{'buf'}.list)).perl,
        .key;
}

# Buffer encode to oid, string not hexadecimal ('g's are not right)
#
if 1 {
  BSON::ObjectId.encode('adeffg0326ffg033aade263a');
  CATCH {
    my $msg = .message;
    $msg ~~ s:g/\n//;
    when X::BSON::Parse {
      ok .message ~~ m:s/'String is not a hexadecimal number'/, $msg;
    }
  }
}

# Buffer encode to oid, string too short
#
if 1 {
  BSON::ObjectId.encode('00');
  CATCH {
    my $msg = .message;
    $msg ~~ s:g/\n//;
    when X::BSON::Parse {
      ok .message ~~ m:s/'String has' \d+ 'characters'/, $msg;
    }
  }
}

# Buffer decode to oid, buffer too short
#
if 1 {
  BSON::ObjectId.decode(Buf.new(0x00));
  CATCH {
    my $msg = .message;
    $msg ~~ s:g/\n//;
    when X::BSON::Parse {
      ok .message ~~ m:s/'Buffer doesn\'t have 12 bytes'/, $msg;
    }
  }
}


# Test cases borrowed from
# https://github.com/mongodb/mongo-python-driver/blob/master/test/test_bson.py

my $oid = BSON::ObjectId.decode(
    Buf.new( 0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
             0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B
           )
);

my BSON::Bson $bson .= new;
is-deeply
    $bson.encode( { "oid" => $oid } ).list,
    [ 0x16, 0x00, 0x00, 0x00,
      0x07,
      0x6F, 0x69, 0x64, 0x00,
      0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
      0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B,
      0x00
    ],
    'encode ObjectId';

$bson._init_index;
is-deeply
    $bson.decode(
      Buf.new( 0x16, 0x00, 0x00, 0x00,                  # Length
               0x07,                                    # object id code
               0x6F, 0x69, 0x64, 0x00,                  # 'oid' + 0
               0x00, 0x01, 0x02, 0x03, 0x04, 0x05,      # object id
               0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B,
               0x00                                     # end doc
             )
    ).{'oid'}.Buf.list,
    [ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
      0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B
    ],
    'decode ObjectId';


#-------------------------------------------------------------------------------
# Cleanup
#
done();
exit(0);
