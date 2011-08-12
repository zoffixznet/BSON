BEGIN { @*INC.unshift( 'lib' ) }

use Test;
use BSON;

plan( 8 );

# Test cases borrowed from
# https://github.com/mongodb/mongo-python-driver/blob/master/test/test_bson.py

my $b = BSON.new( );

my %samples = {

    'Empty object' => {
        'decoded' => { },
        'encoded' => [ 0x05, 0x00, 0x00, 0x00, 0x00 ],
    },

    'UTF-8 string' => {
        'decoded' => { "test" => "hello world" },
        'encoded' => [ 0x1B, 0x00, 0x00, 0x00, 0x02, 0x74, 0x65, 0x73, 0x74, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x77, 0x6F, 0x72, 0x6C, 0x64, 0x00, 0x00 ],
    },

    'Null value' => {
        'decoded' => { "test" => Any },
        'encoded' => [ 0x0B, 0x00, 0x00, 0x00, 0x0A, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00 ],
    },

    '32-bit Integer' => {
        'decoded' => { "mike" => 100 },
        'encoded' => [ 0x0F, 0x00, 0x00, 0x00, 0x10, 0x6D, 0x69, 0x6B, 0x65, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00 ],
    },

    'Boolean "true"' => {
        'decoded' => { "true" => True },
        'encoded' => [ 0x0C, 0x00, 0x00, 0x00, 0x08, 0x74, 0x72, 0x75, 0x65, 0x00, 0x01, 0x00 ],
    },

    'Boolean "false"' => {
        'decoded' => { "false" => False },
        'encoded' => [ 0x0D, 0x00, 0x00, 0x00, 0x08, 0x66, 0x61, 0x6C, 0x73, 0x65, 0x00, 0x00, 0x00 ],
    },

    'Array' => {
        'decoded' => { "empty" => [ ] },
        'encoded' => [ 0x11, 0x00, 0x00, 0x00, 0x04, 0x65, 0x6D, 0x70, 0x74, 0x79, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00 ],
    },

    'Embedded document' => {
        'decoded' => { "none" => { } },
        'encoded' => [ 0x10, 0x00, 0x00, 0x00, 0x03, 0x6E, 0x6F, 0x6E, 0x65, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00 ],
    },

};

for %samples {
    is_deeply
        $b.encode( .value.{ 'decoded' } ).contents,
        .value.{ 'encoded' },
        'encode ' ~ .key;
}

