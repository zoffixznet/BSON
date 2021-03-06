use v6;

use BSON::ObjectId;
use BSON::Regex;
use BSON::Javascript;
use BSON::Binary;

package BSON:ver<0.9.14> {

  #-----------------------------------------------------------------------------
  # BSON type codes
  #
  constant C-DOUBLE             = 0x01;
  constant C-STRING             = 0x02;
  constant C-DOCUMENT           = 0x03;
  constant C-ARRAY              = 0x04;
  constant C-BINARY             = 0x05;
  constant C-UNDEFINED          = 0x06;         # Deprecated
  constant C-OBJECTID           = 0x07;
  constant C-BOOLEAN            = 0x08;
  constant C-DATETIME           = 0x09;
  constant C-NULL               = 0x0A;
  constant C-REGEX              = 0x0B;
  constant C-DBPOINTER          = 0x0C;         # Deprecated
  constant C-JAVASCRIPT         = 0x0D;
  constant C-DEPRECATED         = 0x0E;         # Deprecated
  constant C-JAVASCRIPT-SCOPE   = 0x0F;
  constant C-INT32              = 0x10;
  constant C-TIMESTAMP          = 0x11;         # Used internally
  constant C-INT64              = 0x12;
  constant C-MIN-KEY            = 0xFF;
  constant C-MAX-KEY            = 0x7F;

  #-----------------------------------------------------------------------------
  # Fixed sizes
  #
  constant C-INT32-SIZE         = 4;
  constant C-INT64-SIZE         = 8;
  constant C-DOUBLE-SIZE        = 8;

  #-----------------------------------------------------------------------------
  class X::Parse-document is Exception {
    has $.operation;                      # Operation method
    has $.error;                          # Parse error

    method message () {
      return "\n$!operation error: $!error\n";
    }
  }

  class X::NYS is Exception {
    has $.operation;                      # Operation encode, decode
    has $.type;                           # Type to encode/decode

    method message () {
      return "\n$!operation error: Type '$!type' is not (yet) supported\n";
    }
  }

  #-----------------------------------------------------------------------------
  class Document does Associative does Positional {

    subset Index of Int where $_ >= 0;

    has Str @!keys;
    has @!values;

    has Buf $!encoded-document;
    has Buf @!encoded-entries;
    has Index $!index = 0;

    has Promise %!promises;

    has Bool $.autovivify is rw = False;
    has Bool $.accept-hash is rw = False;

    my Channel $document-ready-to-encode;
    my Bool $toplevel = False;

    #---------------------------------------------------------------------------
    # Make new document and initialize with a list of pairs
    #
    multi method new ( List $pairs ) {
      self.bless(:$pairs);
    }

    # Make new document and initialize with a pair
    # No default value! is handled by new() above
    #
    multi method new ( Pair $p ) {
      my List $pairs = $p.List;
      self.bless(:$pairs);
    }

    # Make new document and initialize with a sequence of pairs
    # No default value! is handled by new() above
    #
    multi method new ( Seq $p ) {
      my List $pairs = $p.List;
      self.bless(:$pairs);
    }

    # Make new document and initialize with a byte array. This will call
    # decode.
    #
    multi method new ( Buf $b ) {
      self.bless(:buf($b));
    }

    # Other cases. No arguments will init empty document. Named values
    # are associative thingies in a Capture and therefore throw an exception.
    #
    multi method new ( |capture ) {
      if ? capture.keys {
        die X::Parse-document.new(
          :operation("new: key => value")
          :error( "Cannot use hash values on init.\n",
                  "Set accept-hash and use assignments later"
                )
        );
      }

      self.bless(:pairs(List.new()));
    }

    #---------------------------------------------------------------------------
    multi submethod BUILD ( List :$pairs! ) {

      self!initialize;

      # self{x} = y will end up at ASSIGN-KEY
      #
      for @$pairs -> $pair {
        self{$pair.key} = $pair.value;
      }
    }

    multi submethod BUILD ( Buf :$buf! ) {

      self!initialize;

      # Decode buffer data
      #
      self.decode($buf);
    }

    #---------------------------------------------------------------------------
    method !initialize (  ) {

      if ! ? $document-ready-to-encode {
        $document-ready-to-encode .= new;
        $toplevel = True;
      }

      @!keys = ();
      @!values = ();

      $!encoded-document = Buf.new();
      @!encoded-entries = ();

      %!promises = ();
    }

    #---------------------------------------------------------------------------
    method perl ( --> Str ) {
      [~] "\n  ", self,
          "\n  Autivivify: $!autovivify",
          "\n  Accept hash: $!accept-hash",
          "\n  Keys(", @!keys.elems, "): ", @!keys.join(', '),
          "\n  Values(", @!values.elems, "): ", @!values.join(', '),
          "\n  Encoded Entries(", @!encoded-entries.elems, "):",
             (map { "\n   - " ~ $_.>>.fmt('0x%02x'); }, @!encoded-entries),
          ;
    }

    #---------------------------------------------------------------------------
    submethod WHAT ( --> Str ) {
      "(BSON::Document)";
    }

    #---------------------------------------------------------------------------
    submethod Str ( --> Str ) {
      "BSON::Document<{self.WHERE}>";
    }

    #---------------------------------------------------------------------------
    submethod DESTROY ( ) {

      @!keys = ();
      @!values = ();

      $!encoded-document = Nil;
      @!encoded-entries = ();

      %!promises = ();
    }

    #---------------------------------------------------------------------------
    method find-key ( Str:D $key --> Int ) {

      my Int $idx;
      loop ( my $i = 0; $i < @!keys.elems; $i++) {
        if @!keys[$i] eq $key {
          $idx = $i;
          last;
        }
      }

      $idx;
    }

    #---------------------------------------------------------------------------
    # Associative role methods
    #---------------------------------------------------------------------------
    method AT-KEY ( Str $key --> Any ) {

      my $value;
      my Int $idx = self.find-key($key);
      if $idx.defined {
        $value = @!values[$idx];
      }

      # No key found so its undefined, check if we must make a new entry
      #
      elsif $!autovivify {
#say "At-key($?LINE): $key => ", $value.WHAT, ", autovivify: $!autovivify;";
        $value = BSON::Document.new;
        $value.accept-hash = $!accept-hash;
        $value.autovivify = True;
        self{$key} = $value;
#say "At-key($?LINE): $key => ", $value.WHAT;
      }

      $value;
    }

    #---------------------------------------------------------------------------
    method EXISTS-KEY ( Str $key --> Bool ) {

      ? self.find-key($key);
    }

    #---------------------------------------------------------------------------
    method DELETE-KEY ( Str $key --> Any ) {

      my $value;
      if (my Int $idx = self.find-key($key)).defined {
        $value = @!values.splice( $idx, 1);
        @!keys.splice( $idx, 1);
        @!encoded-entries.splice( $idx, 1) if @!encoded-entries.elems;
      }

      $value;
    }

    #---------------------------------------------------------------------------
    multi method ASSIGN-KEY ( Str:D $key, Array:D $new --> Nil ) {

#say "Asign-key($?LINE): $key => ", $new.WHAT;

      my Str $k = $key;
      my Array $v = $new;

      my Int $idx = self.find-key($k);
      if $idx.defined {
        %!promises{$k}:delete;
      }

      else {
        $idx = @!keys.elems;
      }

      @!keys[$idx] = $k;
      @!values[$idx] = $v;

      %!promises{$k} = Promise.start({ self!encode-element: ($k => $v); });
    }

    multi method ASSIGN-KEY ( Str:D $key, List:D $new --> Nil ) {

#say "Asign-key($?LINE): $key => ", $new.WHAT, ', ', $new[0].WHAT;

      my Str $k = $key;
      my BSON::Document $v .= new($new);
      $v.accept-hash = $!accept-hash;

      my Int $idx = self.find-key($k);
      if $idx.defined {
        %!promises{$k}:delete;
      }

      else {
        $idx = @!keys.elems;
      }

      @!keys[$idx] = $k;
      @!values[$idx] = $v;

      %!promises{$k} = Promise.start({ self!encode-element: ($k => $v); });
    }

    multi method ASSIGN-KEY ( Str:D $key, Pair $new --> Nil ) {

#say "Asign-key($?LINE): $key => ", $new.WHAT;

      my Str $k = $key;
      my BSON::Document $v .= new: ($new);
      $v.accept-hash = $!accept-hash;

      my Int $idx = self.find-key($k);
      if $idx.defined {
        %!promises{$k}:delete;
      }

      else {
        $idx = @!keys.elems;
      }

      @!keys[$idx] = $k;
      @!values[$idx] = $v;

      %!promises{$k} = Promise.start({ self!encode-element: ($k => $v); });
    }

    multi method ASSIGN-KEY ( Str:D $key, Hash $new --> Nil ) {

#say "Asign-key($?LINE): $key => ", $new.WHAT;

      if ! $!accept-hash {
        die X::Parse-document.new(
          :operation("\$d<$key> = {$new.perl}")
          :error("Cannot use hash values.\nSet accept-hash if you really want to")
        );
      }

      self.ASSIGN-KEY( $key, $new.List);
    }

    multi method ASSIGN-KEY ( Str:D $key, Seq $new --> Nil ) {

#say "Asign-key($?LINE): $key => ", $new.WHAT;
      self.ASSIGN-KEY( $key, $new.List);
    }

    multi method ASSIGN-KEY ( Str:D $key, Any $new --> Nil ) {

#say "Asign-key($?LINE)({self.WHERE}): $key => ", $new.WHAT;

      my Str $k = $key;
      my $v = $new;

      my Int $idx = self.find-key($k);
      if $idx.defined {
        %!promises{$k}:delete;
      }

      else {
        $idx = @!keys.elems;
      }

      @!keys[$idx] = $k;
      @!values[$idx] = $v;

      %!promises{$k} = Promise.start({ self!encode-element: ($k => $v); });
    }

    #---------------------------------------------------------------------------
    # Cannot use binding because when value changes this object cannot know that
    # the location is changed. This is nessesary to encode the key, value pair.
    #
    method BIND-KEY ( Str $key, \new ) {

      die X::Parse-document.new(
        :operation("\$d<$key> := {new}")
        :error("Cannot use binding")
      );
    }


    #---------------------------------------------------------------------------
    # Positional role methods
    #---------------------------------------------------------------------------
    #---------------------------------------------------------------------------
    method AT-POS ( Index $idx --> Any ) {

      $idx < @!keys.elems ?? @!values[$idx] !! Any;
    }

    #---------------------------------------------------------------------------
    method EXISTS-POS ( Index $idx --> Bool ) {

      $idx < @!keys.elems;
    }

    #---------------------------------------------------------------------------
    method DELETE-POS ( Index $idx --> Any ) {

      $idx < @!keys.elems ?? (self{@!keys[$idx]}:delete) !! Nil;
    }

    #---------------------------------------------------------------------------
    method ASSIGN-POS ( Index $idx, $new! --> Nil ) {

      # If index is at a higher position then the last one then only extend
      # one place (like a push) with a generated key name such as key21 when
      # [21] was used. Furthermore when a key like key21 has been used
      # before the array is not extended but the key location is used
      # instead.
      #
      my $key = $idx >= @!keys.elems ?? 'key' ~ $idx !! @!keys[$idx];
      self{$key} = $new;
    }

    #---------------------------------------------------------------------------
    # Cannot use binding because when value changes the object cannot know that
    # the location is changed. This is nessesary to encode the key, value pair.
    #
    method BIND-POS ( Index $idx, \new ) {

      die X::Parse-document.new(
        :operation("\$d[$idx] := {new}")
        :error("Cannot use binding")
      );
    }

    #---------------------------------------------------------------------------
    # Must be defined because of Positional and Associative sources of of()
    #---------------------------------------------------------------------------
    method of ( ) {
      BSON::Document;
    }

    #---------------------------------------------------------------------------
    method CALL-ME ( |capture ) {
      say "Call me capture: ", capture.perl;
    }

    #---------------------------------------------------------------------------
    # And some extra methods
    #---------------------------------------------------------------------------
    method elems ( --> Int ) {

      @!keys.elems;
    }

    #---------------------------------------------------------------------------
    method kv ( --> List ) {

      my @kv-list;
      loop ( my $i = 0; $i < @!keys.elems; $i++) {
        @kv-list.push( @!keys[$i], @!values[$i]);
      }

      @kv-list;
    }

    #---------------------------------------------------------------------------
    method keys ( --> List ) {

      @!keys.list;
    }

    #---------------------------------------------------------------------------
    method values ( --> List ) {

      @!values.list;
    }

    #---------------------------------------------------------------------------
    # Encoding document
    #---------------------------------------------------------------------------
    # Called from user to get encoded document
    #
    method encode ( --> Buf ) {

#say "Nbr promises({self.WHERE}): ", %!promises.elems;
      $document-ready-to-encode.send('encode') if $toplevel;

      if %!promises.elems {
#        try {
          loop ( my $idx = 0; $idx < @!keys.elems; $idx++) {
            my $key = @!keys[$idx];
            if %!promises{$key}:exists {
              @!encoded-entries[$idx] = %!promises{$key}.result;
#say "Pr({self.WHERE}): $idx, $key, ",
#    @!values[$idx].WHAT, ', ',
#    @!encoded-entries[$idx];
            }
          }

#          CATCH {
#            default {
#              say "Error encoding: ", $_; #%!promises{$key}.cause;
#            }
#          }
#        }

        %!promises = ();
      }

#say "Nbr encoded entries({self.WHERE}): ", @!encoded-entries.elems;
#my $i = 0;
#for @!encoded-entries -> $ee {
#  say "({self.WHERE}): @!keys[$i++]: ", $ee;
#}

      my Buf $b;
      if @!encoded-entries.elems {
        $!encoded-document = [~] @!encoded-entries;
        $b = [~] encode-int32($!encoded-document.elems + 5),
                 $!encoded-document,
                 Buf.new(0x00);
      }

      else {
        $b = [~] encode-int32(5), Buf.new(0x00);
      }

#say "({self.WHERE}). Encoded ($?LINE): ", $b;

      return $b;
    }

    #---------------------------------------------------------------------------
    # Encode a key value pair. Called from the insertion methods above when a
    # key value pair is inserted.
    #
    # element ::= type-code e_name some-encoding
    #
    method !encode-element ( Pair:D $p --> Buf ) {

      my Buf $b;

      given $p.value {

        when Num {
          # Double precision
          # "\x01" e_name Num
          #
          $b = [~] Buf.new(BSON::C-DOUBLE),
                     encode-e-name($p.key),
                     encode-double($p.value);
        }

        when Str {
          # UTF-8 string
          # "\x02" e_name string
          #
          $b = [~] Buf.new(BSON::C-STRING),
                     encode-e-name($p.key),
                     encode-string($p.value);
        }

#`{{
        # Converting a pair same way as a hash:
        #
        when Pair {
          # Embedded document
          # "\x03" e_name document
          #
          my Pair @pairs = $p.value;
#say "Pair {$p.key} => {$p.value}: ", [~] Buf.new(BSON::C-DOCUMENT),
#                     encode-e-name($p.key),
#                     self!encode-document(@pairs);
          $b = [~] Buf.new(BSON::C-DOCUMENT),
                     encode-e-name($p.key),
                     self!encode-document(@pairs);
        }

        when Hash {
          # Embedded document
          # "\x03" e_name document
          #
          $b = [~] Buf.new(C-DOCUMENT),
                     encode-e-name($p.key),
                     self!encode-document($p.value);
        }
}}
        when BSON::Document {
          # Embedded document
          # "\x03" e_name document
          #
          # When there is a deep nesting of docments it is possible that the
          # encoding of it below is finished before AT-KEY or ASSIGN-KEY on that
          # same document is called to add a new key resulting effectively
          # in a pruned tree. Trick is to wait for a signal from the channel
          # before starting it.
          #
          my $cmd = $document-ready-to-encode.receive;
#say "Command received: $cmd";
          $b = [~] Buf.new(BSON::C-DOCUMENT),
                     encode-e-name($p.key),
                     .encode;
#say "Encoded doc ($?LINE): ", $b;
        }

        when Array {
          # Array
          # "\x04" e_name document

          # The document for an array is a normal BSON document
          # with integer values for the keys,
          # starting with 0 and continuing sequentially.
          # For example, the array ['red', 'blue']
          # would be encoded as the document {'0': 'red', '1': 'blue'}.
          # The keys must be in ascending numerical order.
          #
          # Simple assigning .kv to %hash wouldn't work because the order
          # of items can go wrong. Mongo doesn't process it very well if e.g.
          # { 1 => 'abc', 0 => 'def' } was encoded instead of
          # { 0 => 'def', 1 => 'abc' }.
          #
          my BSON::Document $d .= new(
            (('0' ...^ $p.value.elems.Str) Z=> $p.value).List
          );
          $d.accept-hash = $!accept-hash;
          $b = [~] Buf.new(BSON::C-ARRAY), encode-e-name($p.key), $d.encode;
        }

        when BSON::Binary {
          # Binary data
          # "\x05" e_name int32 subtype byte*
          # subtype is '\x00' for the moment (Generic binary subtype)
          #
          $b = [~] Buf.new(BSON::C-BINARY), encode-e-name($p.key);

          if .has-binary-data {
            $b ~= encode-int32(.binary-data.elems);
            $b ~= Buf.new(.binary-type);
            $b ~= .binary-data;
          }

          else {
            $b ~= encode-int32(0);
            $b ~= Buf.new(.binary-type);
          }
        }

       when BSON::ObjectId {
          # ObjectId
          # "\x07" e_name (byte*12)
          #
          $b = Buf.new(BSON::C-OBJECTID) ~ encode-e-name($p.key) ~ .oid;
        }

        when Bool {
          # Bool
          # \0x08 e_name (\0x00 or \0x01)
          #
          if .Bool {
            # Boolean "true"
            # "\x08" e_name "\x01
            #
            $b = [~] Buf.new(BSON::C-BOOLEAN),
                       encode-e-name($p.key),
                       Buf.new(0x01);
          }
          else {
            # Boolean "false"
            # "\x08" e_name "\x00
            #
            $b = [~] Buf.new(BSON::C-BOOLEAN),
                       encode-e-name($p.key),
                       Buf.new(0x00);
          }
        }

        when DateTime {
          # UTC dateime
          # "\x09" e_name int64
          #
          $b = [~] Buf.new(BSON::C-DATETIME),
                     encode-e-name($p.key),
                     encode-int64(.posix);
        }

        when not .defined {
          # Nil == Undefined value == typed object
          # "\x0A" e_name
          #
          $b = Buf.new(BSON::C-NULL) ~ encode-e-name($p.key);
        }

        when BSON::Regex {
          # Regular expression
          # "\x0B" e_name cstring cstring
          #
          $b = [~] Buf.new(BSON::C-REGEX),
                     encode-e-name($p.key),
                     encode-cstring(.regex),
                     encode-cstring(.options);
        }

#`{{
        when ... {
          # DBPointer - deprecated
          # "\x0C" e_name string (byte*12)
          #
          die X::BSON::Deprecated(
            operation => 'encoding DBPointer',
            type => '0x0C'
          );
        }
}}

        # This entry does 2 codes. 0x0D for javascript only and 0x0F when
        # there is a scope document defined in the object
        #
        when BSON::Javascript {

          # Javascript code
          # "\x0D" e_name string
          # "\x0F" e_name int32 string document
          #
          if .has-javascript {
            my Buf $js = encode-string(.javascript);

            if .has-scope {
              my Buf $doc = .scope.encode;
              $b = [~] Buf.new(BSON::C-JAVASCRIPT-SCOPE),
                         encode-e-name($p.key),
                         $js, $doc;
            }

            else {
              $b = [~] Buf.new(BSON::C-JAVASCRIPT), encode-e-name($p.key), $js;
            }
          }

          else {
            die X::Parse-document.new(
              :operation('encode Javscript'),
              :error('cannot send empty code')
            );
          }
        }

        when Int {
          # Integer
          # "\x10" e_name int32
          # '\x12' e_name int64
          #
          if -0xffffffff < $p.value < 0xffffffff {
            $b = [~] Buf.new(BSON::C-INT32),
                       encode-e-name($p.key),
                       encode-int32($p.value)
                       ;
          }

          elsif -0x7fffffff_ffffffff < $p.value < 0x7fffffff_ffffffff {
            $b = [~] Buf.new(BSON::C-INT64),
                       encode-e-name($p.key),
                       encode-int64($p.value)
                       ;
          }

          else {
            my $reason = 'small' if $p.value < -0x7fffffff_ffffffff;
            $reason = 'large' if $p.value > 0x7fffffff_ffffffff;
            die X::Parse-document.new(
              :operation('encode Int'),
              :error("Number too $reason")
            );
          }
        }

#`{{
        when ... {
            # Timestamp. 
            # "\x11" e_name int64
            #
            # Special internal type used by MongoDB replication and
            # sharding. First 4 bytes are an increment, second 4 are a
            # timestamp.
        }
}}

        # Buf is converted to BSON binary with generic type. When decoding it
        # will always be BSON::Binary again. Buf can be retrieved with
        # $o.binary-data;
        #
        when Buf {
          my BSON::Binary $bbin .= new(:data($_));
          $b = [~] Buf.new(BSON::C-BINARY), encode-e-name($p.key);
          $b ~= encode-int32(.binary-data.elems);
          $b ~= Buf.new(.binary-type);
          $b ~= .binary-data;
        }

        default {
          if .can('encode') and .can('bson-code') {
            my $code = .bson-code;
            $b = [~] Buf.new($code), encode-e-name($p.key), .encode;
          }

          else {
            die X::NYS.new( :operation('encode-element()'), :type($_));
          }
        }
      }

#say "\nEE: ", ", {$p.key} => {$p.value//'(Any)'}: ", $p.value.WHAT, ', ', $b;

      $b;
    }

    #---------------------------------------------------------------------------
    sub encode-e-name ( Str:D $s --> Buf ) {
      return encode-cstring($s);
    }

    #---------------------------------------------------------------------------
    sub encode-cstring ( Str:D $s --> Buf ) {
      die X::Parse-document.new(
        :operation('encode-cstring()'),
        :error('Forbidden 0x00 sequence in $s')
      ) if $s ~~ /\x00/;

      return $s.encode() ~ Buf.new(0x00);
    }

    #---------------------------------------------------------------------------
    sub encode-string ( Str:D $s --> Buf ) {
      my Buf $b .= new($s.encode('UTF-8'));
      return [~] encode-int32($b.bytes + 1), $b, Buf.new(0x00);
    }

    #---------------------------------------------------------------------------
    sub encode-int32 ( Int:D $i --> Buf ) {
      my int $ni = $i;      
      return Buf.new( $ni +& 0xFF, ($ni +> 0x08) +& 0xFF,
                      ($ni +> 0x10) +& 0xFF, ($ni +> 0x18) +& 0xFF
                    );
    }

    #---------------------------------------------------------------------------
    sub encode-int64 ( Int:D $i --> Buf ) {
      # No tests for too large/small numbers because it is called from
      # enc-element normally where it is checked
      #
      my int $ni = $i;
      return Buf.new( $ni +& 0xFF, ($ni +> 0x08) +& 0xFF,
                      ($ni +> 0x10) +& 0xFF, ($ni +> 0x18) +& 0xFF,
                      ($ni +> 0x20) +& 0xFF, ($ni +> 0x28) +& 0xFF,
                      ($ni +> 0x30) +& 0xFF, ($ni +> 0x38) +& 0xFF
                    );
    }

    #---------------------------------------------------------------------------
    sub encode-double ( Num:D $r is copy --> Buf ) {

      # Make array starting with bson code 0x01 and the key name
      my Buf $a = Buf.new(); # Buf.new(0x01) ~ encode-e-name($key-name);
      my Num $r2;

      # Test special cases
      #
      # 0x 0000 0000 0000 0000 = 0
      # 0x 8000 0000 0000 0000 = -0       Not recognizable
      # 0x 7ff0 0000 0000 0000 = Inf
      # 0x fff0 0000 0000 0000 = -Inf
      # 0x 7ff0 0000 0000 0001 <= nan <= 0x 7ff7 ffff ffff ffff signalling NaN
      # 0x fff0 0000 0000 0001 <= nan <= 0x fff7 ffff ffff ffff
      # 0x 7ff8 0000 0000 0000 <= nan <= 0x 7fff ffff ffff ffff quiet NaN
      # 0x fff8 0000 0000 0000 <= nan <= 0x ffff ffff ffff ffff
      #
      given $r {
        when 0.0 {
          $a ~= Buf.new(0 xx 8);
        }

        when -Inf {
          $a ~= Buf.new( 0 xx 6, 0xF0, 0xFF);
        }

        when Inf {
          $a ~= Buf.new( 0 xx 6, 0xF0, 0x7F);
        }

        when NaN {
          # Choose only one number out of the quiet NaN range
          #
          $a ~= Buf.new( 0 xx 6, 0xF8, 0x7F);
        }

        default {
          my Int $sign = $r.sign == -1 ?? -1 !! 1;
          $r *= $sign;

          # Get proper precision from base(2). Adjust the exponent bias for
          # this.
          #
          my Int $exp-shift = 0;
          my Int $exponent = 1023;
          my Str $bit-string = $r.base(2);

          $bit-string ~= '.' unless $bit-string ~~ m/\./;

          # Smaller than one
          #
          if $bit-string ~~ m/^0\./ {

            # Normalize, Check if a '1' is found. Possible situation is
            # a series of zeros because r.base(2) won't give that much
            # information.
            #
            my $first-one;
            while !($first-one = $bit-string.index('1')) {
              $exponent -= 52;
              $r *= 2 ** 52;
              $bit-string = $r.base(2);
            }

            $first-one--;
            $exponent -= $first-one;

            $r *= 2 ** $first-one;                # 1.***
            $r2 = $r * 2 ** 52;                   # Get max precision
            $bit-string = $r2.base(2);            # Get bits
            $bit-string ~~ s/\.//;                # Remove dot
            $bit-string ~~ s/^1//;                # Remove first 1
          }

          # Bigger than one
          #
          else {
            # Normalize
            #
            my Int $dot-loc = $bit-string.index('.');
            $exponent += ($dot-loc - 1);

            # If dot is in the string, not at the end, the precision might
            # be not sufficient. Enlarge one time more
            #
            my Int $str-len = $bit-string.chars;
            if $dot-loc < $str-len - 1 or $str-len < 52 {
              $r2 = $r * 2 ** 52;                 # Get max precision
              $bit-string = $r2.base(2);          # Get bits
            }

            $bit-string ~~ s/\.//;              # Remove dot
            $bit-string ~~ s/^1//;              # Remove first 1
          }

          # Prepare the number. First set the sign bit.
          #
          my Int $i = $sign == -1 ?? 0x8000_0000_0000_0000 !! 0;

          # Now fit the exponent on its place
          #
          $i +|= $exponent +< 52;

          # And the precision
          #
          $i +|= :2($bit-string.substr( 0, 52));

          $a ~= encode-int64($i);
        }
      }

      return $a;
    }

    #---------------------------------------------------------------------------
    # Decoding document
    #---------------------------------------------------------------------------
    method decode ( Buf $data --> Nil ) {

      $!encoded-document = $data;

      @!keys = ();
      @!values = ();
      @!encoded-entries = ();

      # Document decoding start: init index
      #
      $!index = 0;

      # Decode the document, then wait for any started parallel tracks
      #
      self!decode-document;

      if %!promises.elems {
#        try {
          loop ( my $idx = 0; $idx < @!keys.elems; $idx++) {
            my $key = @!keys[$idx];
            if %!promises{$key}:exists {

              # Return the Buffer slices in each entry so it can be
              # concatenated again when encoding
              #
              @!encoded-entries[$idx] = %!promises{$key}.result;
            }
          }

#          CATCH {
#            default {
#              say "Error decoding: ", $_;
#            }
#          }
#        }

        %!promises = ();
      }
    }

    #---------------------------------------------------------------------------
    method !decode-document ( --> Nil ) {

      # Get the size of the (nested-)document
      #
      my Int $doc-size = decode-int32( $!encoded-document, $!index);
      $!index += C-INT32-SIZE;

      while $!encoded-document[$!index] !~~ 0x00 {
        self!decode-element;
      }

      $!index++;

      # Check size of document with final byte location
      #
      die X::Parse-document.new(
        :operation<decode-document()>,
        :error(
          [~] 'Size of document(', $doc-size,
              ') does not match with index(', $!index, ')'
        )
      ) if $doc-size != $!index;
    }

    #---------------------------------------------------------------------------
    method !decode-element ( --> Nil ) {

      # Decode start point
      #
      my $decode-start = $!index;

      # Get the value type of next pair
      #
      my $bson-code = $!encoded-document[$!index++];

      # Get the key value, Index is adjusted to just after the 0x00
      # of the string.
      #
      my Str $key = decode-e-name( $!encoded-document, $!index);

      # Keys are pushed in the proper order as they are seen in the
      # byte buffer.
      #
      my Int $idx = @!keys.elems;
      @!keys[$idx] = $key;              # index on new location == push()
      my Int $size;

      given $bson-code {

        # 64-bit floating point
        #
        when BSON::C-DOUBLE {

          my Int $i = $!index;
          $!index += BSON::C-DOUBLE-SIZE;

          %!promises{$key} = Promise.start( {
              @!values[$idx] = decode-double( $!encoded-document, $i);

              Buf.new(
                $!encoded-document[
                  $decode-start ..^ ($i + BSON::C-DOUBLE-SIZE)
                ]
              );
            }
          );
        }

        # String type
        #
        when BSON::C-STRING {

          my Int $i = $!index;
          my Int $nbr-bytes = decode-int32( $!encoded-document, $!index);

          # Step over the size field and the null terminated string
          #
          $!index += BSON::C-INT32-SIZE + $nbr-bytes;

          %!promises{$key} = Promise.start( {
              @!values[$idx] = decode-string( $!encoded-document, $i);
              Buf.new(
                $!encoded-document[
                  $decode-start ..^ ($i + BSON::C-INT32-SIZE + $nbr-bytes)
                ]
              );
            }
          );
        }

        # Nested document
        #
        when BSON::C-DOCUMENT {
          my Int $i = $!index;
          my Int $doc-size = decode-int32( $!encoded-document, $i);
          $!index += $doc-size;

          # Keep this decoding out of the promise routine. It gets problems
          # when waiting for it.
          #
          my BSON::Document $d .= new;
          $d.accept-hash = $!accept-hash;
          $d.decode(Buf.new($!encoded-document[$i ..^ ($i + $doc-size)]));
          @!values[$idx] = $d;

          %!promises{$key} = Promise.start( {
              Buf.new(
                $!encoded-document[
                  $decode-start ..^ ($i + $doc-size)
                ]
              );
            }
          );
        }

        # Array code
        #
        when BSON::C-ARRAY {

          my Int $i = $!index;
          my Int $doc-size = decode-int32( $!encoded-document, $!index);
          $!index += $doc-size;

          %!promises{$key} = Promise.start( {
              my BSON::Document $d .= new;
              $d.accept-hash = $!accept-hash;

              $d.decode(Buf.new($!encoded-document[$i ..^ ($i + $doc-size)]));
              @!values[$idx] = [$d.values];

              Buf.new(
                $!encoded-document[
                  $decode-start ..^ ($i + $doc-size)
                ]
              );
            }
          );
        }

        # Binary code
        # "\x05 e_name int32 subtype byte*
        # subtype = byte \x00 .. \x05, .. \xFF
        # subtypes \x80 to \xFF are user defined
        #
        when BSON::C-BINARY {

          my Int $nbr-bytes = decode-int32( $!encoded-document, $!index);
          my Int $i = $!index + C-INT32-SIZE;

          # Step over size field, subtype and binary data
          #
          $!index += C-INT32-SIZE + 1 + $nbr-bytes;

          %!promises{$key} = Promise.start( {
              @!values[$idx] = decode-binary(
                $!encoded-document,
                $i,
                $nbr-bytes
              );

              Buf.new(
                $!encoded-document[
                  $decode-start ..^ ($i + 1 + $nbr-bytes)
                ]
              );
            }
          );
        }

        # Object id
        #
        when BSON::C-OBJECTID {

          my Int $i = $!index;
          $!index += 12;

          %!promises{$key} = Promise.start( {
              @!values[$idx] = BSON::ObjectId.new(
                :bytes($!encoded-document[$i ..^ ($i + 12)])
              );

              Buf.new(
                $!encoded-document[
                  $decode-start ..^ ($i + 12)
                ]
              );
            }
          );
        }

        # Boolean code
        #
        when BSON::C-BOOLEAN {

          my Int $i = $!index;
          $!index++;

          %!promises{$key} = Promise.start( {
              @!values[$idx] = $!encoded-document[$i] ~~ 0x00 ?? False !! True;

              Buf.new(
                $!encoded-document[
                  $decode-start .. ($i + 1)
                ]
              );
            }
          );
        }

        # Datetime code
        #
        when BSON::C-DATETIME {
          my Int $i = $!index;
          $!index += BSON::C-INT64-SIZE;

          %!promises{$key} = Promise.start( {
              @!values[$idx] = DateTime.new(
                decode-int64( $!encoded-document, $i),
                :timezone($*TZ)
              );

              Buf.new(
                $!encoded-document[
                  $decode-start ..^ ($i + BSON::C-INT64-SIZE)
                ]
              );
            }
          );
        }

        when BSON::C-NULL {
          %!promises{$key} = Promise.start( {
              @!values[$idx] = Any;

              my $i = $!index;
              Buf.new(
                $!encoded-document[
                  $decode-start ..^ $i
                ]
              );
            }
          );
        }

        when BSON::C-REGEX {

          my $doc-size = $!encoded-document.elems;
          my $i1 = $!index;
          while $!encoded-document[$!index] !~~ 0x00 and $!index < $doc-size {
            $!index++;
          }
          $!index++;
          my $i2 = $!index;

          while $!encoded-document[$!index] !~~ 0x00 and $!index < $doc-size {
            $!index++;
          }
          $!index++;
          my $i3 = $!index;

          %!promises{$key} = Promise.start( {
              @!values[$idx] = BSON::Regex.new(
                :regex(decode-cstring( $!encoded-document, $i1)),
                :options(decode-cstring( $!encoded-document, $i2))
              );

              Buf.new(
                $!encoded-document[
                  $decode-start ..^ $i3
                ]
              );
            }
          );
        }

        # Javascript code
        #
        when BSON::C-JAVASCRIPT {

          # Get the size of the javascript code text, then adjust index
          # for this size and set i for the decoding. Then adjust index again
          # for the next action.
          #
          my Int $i = $!index;
          my Int $js-size = decode-int32( $!encoded-document, $i);

          # Step over size field and the javascript text
          #
          $!index += (BSON::C-INT32-SIZE + $js-size);

          %!promises{$key} = Promise.start( {
              @!values[$idx] = BSON::Javascript.new(
                :javascript(decode-string( $!encoded-document, $i))
              );

              Buf.new(
                $!encoded-document[
                  $decode-start ..^ ($i + BSON::C-INT32-SIZE + $js-size)
                ]
              );
            }
          );
        }

        # Javascript code with scope
        #
        when BSON::C-JAVASCRIPT-SCOPE {

          my Int $i1 = $!index;
          my Int $js-size = decode-int32( $!encoded-document, $i1);
          my Int $i2 = $!index + C-INT32-SIZE + $js-size;
          my Int $js-scope-size = decode-int32( $!encoded-document, $i2);

          $!index += (BSON::C-INT32-SIZE + $js-size + $js-scope-size);
          my Int $i3 = $!index;

          %!promises{$key} = Promise.start( {
              my BSON::Document $d .= new;
              $d.accept-hash = $!accept-hash;
              $d.decode(Buf.new($!encoded-document[$i2 ..^ ($i2 + $js-size)]));
              @!values[$idx] = BSON::Javascript.new(
                :javascript(decode-string( $!encoded-document, $i1)),
                :scope($d)
              );

              Buf.new(
                $!encoded-document[
                  $decode-start ..^ $i3
                ]
              );
            }
          );
        }

        # 32-bit Integer
        #
        when BSON::C-INT32 {

          my Int $i = $!index;
          $!index += BSON::C-INT32-SIZE;

          %!promises{$key} = Promise.start( {
              @!values[$idx] = decode-int32( $!encoded-document, $i);

              Buf.new(
                $!encoded-document[
                  $decode-start ..^ ($i + BSON::C-INT32-SIZE)
                ]
              );
            }
          );
        }

        # 64-bit Integer
        #
        when BSON::C-INT64 {

          my Int $i = $!index;
          $!index += BSON::C-INT64-SIZE;

          %!promises{$key} = Promise.start( {
              @!values[$idx] = decode-int64( $!encoded-document, $i);

              Buf.new(
                $!encoded-document[
                  $decode-start ..^ ($i + BSON::C-INT64-SIZE)
                ]
              );
            }
          );
        }

        default {
          # We must stop because we do not know what the length should be of
          # this particular structure.
          #
          die X::Parse-document.new(
            :operation<decode-element()>,
            :error("BSON code '{.fmt('0x%02x')}' not supported")
          );
        }
      }
    }

    #-----------------------------------------------------------------------------
    sub decode-e-name ( Buf:D $b, Int:D $index is rw --> Str ) {
      return decode-cstring( $b, $index);
    }

    #-----------------------------------------------------------------------------
    sub decode-cstring ( Buf:D $b, Int:D $index is rw --> Str ) {

      my @a;
      my $l = $b.elems;

      while $b[$index] !~~ 0x00 and $index < $l {
        @a.push($b[$index++]);
      }

      # This takes only place if there are no 0x0 characters found until the
      # end of the buffer which is almost never.
      #
      die X::Parse-document.new(
        :operation<decode-cstring>,
        :error('Missing trailing 0x00')
      ) unless $index < $l and $b[$index++] ~~ 0x00;

      return Buf.new(@a).decode();
    }

    #-----------------------------------------------------------------------------
    sub decode-string ( Buf:D $b, Int:D $index is copy --> Str ) {

      my $size = decode-int32( $b, $index);
      my $end-string-at = $index + 4 + $size - 1;

      # Check if there are enaugh letters left
      #
      die X::Parse-document.new(
        :operation<decode-string>,
        :error('Not enaugh characters left')
      ) unless ($b.elems - $size) > $index;

      die X::Parse-document.new(
        :operation<decode-string>,
        :error('Missing trailing 0x00')
      ) unless $b[$end-string-at] == 0x00;

      return Buf.new($b[$index+4 ..^ $end-string-at]).decode;
    }

    #-----------------------------------------------------------------------------
    sub decode-int32 ( Buf:D $b, Int:D $index --> Int ) {

      # Check if there are enaugh letters left
      #
      die X::Parse-document.new(
        :operation<decode-int32>,
        :error('Not enaugh characters left')
      ) if $b.elems - $index < 4;

      my int $ni = $b[$index]             +| $b[$index + 1] +< 0x08 +|
                   $b[$index + 2] +< 0x10 +| $b[$index + 3] +< 0x18
                   ;

      # Test if most significant bit is set. If so, calculate two's complement
      # negative number.
      # Prefix +^: Coerces the argument to Int and does a bitwise negation on
      # the result, assuming two's complement. (See
      # http://doc.perl6.org/language/operators^)
      # Infix +^ :Coerces both arguments to Int and does a bitwise XOR
      # (exclusive OR) operation.
      #
      $ni = (0xffffffff +& (0xffffffff+^$ni) +1) * -1  if $ni +& 0x80000000;
      return $ni;
    }

    #-----------------------------------------------------------------------------
    sub decode-int64 ( Buf:D $b, Int:D $index --> Int ) {
      # Check if there are enaugh letters left
      #
      die X::Parse-document.new(
        :operation<decode-int64>,
        :error('Not enaugh characters left')
      ) if $b.elems - $index < 8;

      my int $ni = $b[$index]             +| $b[$index + 1] +< 0x08 +|
                   $b[$index + 2] +< 0x10 +| $b[$index + 3] +< 0x18 +|
                   $b[$index + 4] +< 0x20 +| $b[$index + 5] +< 0x28 +|
                   $b[$index + 6] +< 0x30 +| $b[$index + 7] +< 0x38
                   ;
      return $ni;
    }

    #---------------------------------------------------------------------------
    # We have to do some simulation using the information on
    # http://en.wikipedia.org/wiki/Double-precision_floating-point_format#Endianness
    # until better times come.
    #
    sub decode-double ( Buf:D $b, Int:D $index --> Num ) {

      # Test special cases
      #
      # 0x 0000 0000 0000 0000 = 0
      # 0x 8000 0000 0000 0000 = -0
      # 0x 7ff0 0000 0000 0000 = Inf
      # 0x fff0 0000 0000 0000 = -Inf
      # 0x 7ff0 0000 0000 0001 <= nan <= 0x 7ff7 ffff ffff ffff signalling NaN
      # 0x fff0 0000 0000 0001 <= nan <= 0x fff7 ffff ffff ffff
      # 0x 7ff8 0000 0000 0000 <= nan <= 0x 7ff7 ffff ffff ffff quiet NaN
      # 0x fff8 0000 0000 0000 <= nan <= 0x ffff ffff ffff ffff
      #
      my Bool $six-byte-zeros = True;
      for ^6 -> $i {
        if ? $b[$i] {
          $six-byte-zeros = False;
          last;
        }
      }

      my Num $value;
      if $six-byte-zeros and $b[6] == 0 {
        if $b[7] == 0 {
          $value .= new(0);
        }

        elsif $b[7] == 0x80 {
          $value .= new(-0);
        }
      }

      elsif $six-byte-zeros and $b[6] == 0xF0 {
        if $b[7] == 0x7F {
          $value .= new(Inf);
        }

        elsif $b[7] == 0xFF {
          $value .= new(-Inf);
        }
      }

      elsif $b[7] == 0x7F and (0xf0 <= $b[6] <= 0xf7 or 0xf8 <= $b[6] <= 0xff) {
        $value .= new(NaN);
      }

      elsif $b[7] == 0xFF and (0xf0 <= $b[6] <= 0xf7 or 0xf8 <= $b[6] <= 0xff) {
        $value .= new(NaN);
      }

      # If value is not set by the special cases above, calculate it here
      #
      if !$value.defined {

        my Int $i = decode-int64( $b, $index);
        my Int $sign = $i +& 0x8000_0000_0000_0000 ?? -1 !! 1;

        # Significand + implicit bit
        #
        my $significand = 0x10_0000_0000_0000 +| ($i +& 0xF_FFFF_FFFF_FFFF);

        # Exponent - bias (1023) - the number of bits for precision
        #
        my $exponent = (($i +& 0x7FF0_0000_0000_0000) +> 52) - 1023 - 52;

        $value = Num.new((2 ** $exponent) * $significand * $sign);
      }

      return $value;
    }

    #---------------------------------------------------------------------------
    sub decode-binary (
      Buf:D $b, Int:D $index is copy, Int:D $nbr-bytes
      --> BSON::Binary
    ) {

      # Get subtype
      #
      my $sub_type = $b[$index++];

      # Most of the tests are not necessary because of arbitrary sizes.
      # UUID and MD5 can be tested.
      #
      given $sub_type {
        when BSON::C-GENERIC {
          # Generic binary subtype
        }

        when BSON::C-FUNCTION {
          # Function
        }

        when BSON::C-BINARY-OLD {
          # Binary (Old - deprecated)
          die X::Parse-document.new(
            :operantion<decode Binary>,
            :error('Code (0x02) Deprecated binary data')
          );
        }

        when BSON::C-UUID-OLD {
          # UUID (Old - deprecated)
          die 'UUID(0x03) Deprecated binary data';
          die X::Parse-document.new(
            :operantion<decode Binary>,
            :error('UUID(0x03) Deprecated binary data')
          );
        }

        when BSON::C-UUID {
          # UUID. According to
          # http://en.wikipedia.org/wiki/Universally_unique_identifier the
          # universally unique identifier is a 128-bit (16 byte) value.
          #
          die X::Parse-document.new(
            :operation('decode Binary'),
            :error('UUID(0x04) Length mismatch')
          ) unless $nbr-bytes ~~ BSON::C-UUID-SIZE;
        }

        when BSON::C-MD5 {
          # MD5. This is a 16 byte number (32 character hex string)
          die X::Parse-document.new(
            :operation('decode Binary'),
            :error('MD5(0x05) Length mismatch')
          ) unless $nbr-bytes ~~ BSON::C-MD5-SIZE;
        }

        when 0x80 {
          # User defined. That is, all other codes 0x80 .. 0xFF
        }
      }

      return BSON::Binary.new(
        :data(Buf.new($b[$index ..^ ($index + $nbr-bytes)])),
        :type($sub_type)
      );
    }
  }
}

