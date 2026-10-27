# encoding: utf-8

# Property list reading and writing.
#
#   OSX::PropertyList.load(string_or_io)        # → object
#   OSX::PropertyList.load(string_or_io, true)  # → [object, format]
#   OSX::PropertyList.dump(io, object, format)
#   object.to_plist(format)
#
# The format is :xml1 (the default), :binary1, or :openstep. XML is parsed and
# generated here, the other formats are converted with plutil(1). Data is
# returned as a String for which blob? is true, dates as Time.

require 'strscan'
require 'time'

module OSX
  module PropertyList
    class ParseError < StandardError; end

    FORMATS = [ :xml1, :binary1, :openstep ]

    class << self
      def load(obj, want_format = false)
        data = obj.respond_to?(:read) ? obj.read : obj.to_s
        data = data.dup.force_encoding('BINARY')

        if data.start_with?('bplist')
          res = BinaryParser.new(data).parse
          return want_format ? [ res, :binary1 ] : res
        elsif data =~ /\A(?:\xEF\xBB\xBF)?\s*<(?:\?xml|!DOCTYPE|plist)/n
          format = :xml1
          xml    = data
        else
          format = :openstep
          xml    = plutil(data, 'xml1')
        end

        res = XMLParser.new(xml.force_encoding('UTF-8')).parse
        want_format ? [ res, format ] : res
      end

      def dump(io, obj, format = :xml1)
        io << obj.to_plist(format)
      end

      def generate(obj, format = :xml1)
        raise ArgumentError, "Argument 2 must be one of :xml1, :binary1, or :openstep" unless FORMATS.include?(format)
        case format
        when :xml1     then XMLGenerator.new.document(obj)
        when :openstep then OpenStepGenerator.new.generate(obj, 0)
        when :binary1  then plutil(XMLGenerator.new.document(obj), 'binary1')
        end
      end

      private

      def plutil(data, format)
        res = ::IO.popen([ '/usr/bin/plutil', '-convert', format, '-o', '-', '-' ], 'r+b', err: File::NULL) do |io|
          writer = Thread.new { io.write(data); io.close_write }
          out = io.read
          writer.join
          out
        end
        raise ParseError, "Unable to parse property list" unless $?.success?
        res
      end
    end

    # Reads the “bplist00” format (see CFBinaryPList.c)
    class BinaryParser
      EPOCH = Time.utc(2001, 1, 1)

      def initialize(data)
        @data = data
      end

      def parse
        raise ParseError, "Truncated binary property list" if @data.bytesize < 40
        trailer = @data.byteslice(-32, 32)
        @offset_size, @ref_size = trailer.unpack('x6CC')
        count, top, table = trailer.byteslice(8, 24).unpack('Q>3')
        @offsets = (0...count).map { |i| uint(table + i * @offset_size, @offset_size) }
        object(top)
      rescue ArgumentError, TypeError, NoMethodError, RangeError => e
        raise ParseError, "Invalid binary property list: #{e.message}"
      end

      private

      def uint(pos, size)
        @data.byteslice(pos, size).bytes.inject(0) { |res, byte| (res << 8) | byte }
      end

      def length_and_pos(marker, pos)
        length = marker & 0x0F
        return [ length, pos + 1 ] unless length == 0x0F
        size = 1 << (@data.getbyte(pos + 1) & 0x0F)
        [ uint(pos + 2, size), pos + 2 + size ]
      end

      def refs(pos, count)
        (0...count).map { |i| uint(pos + i * @ref_size, @ref_size) }
      end

      def object(ref)
        pos    = @offsets.fetch(ref)
        marker = @data.getbyte(pos)
        case marker >> 4
        when 0x0
          case marker
          when 0x08 then false
          when 0x09 then true
          else nil
          end
        when 0x1
          size  = 1 << (marker & 0x0F)
          value = uint(pos + 1, size)
          size == 8 && value >= 2**63 ? value - 2**64 : value
        when 0x2 then (marker & 0x0F) == 2 ? @data.byteslice(pos + 1, 4).unpack1('g') : @data.byteslice(pos + 1, 8).unpack1('G')
        when 0x3 then EPOCH + @data.byteslice(pos + 1, 8).unpack1('G')
        when 0x4
          length, start = length_and_pos(marker, pos)
          str = @data.byteslice(start, length)
          str.blob = true
          str
        when 0x5
          length, start = length_and_pos(marker, pos)
          @data.byteslice(start, length).force_encoding('UTF-8')
        when 0x6
          length, start = length_and_pos(marker, pos)
          @data.byteslice(start, length * 2).force_encoding('UTF-16BE').encode('UTF-8')
        when 0x8 then uint(pos + 1, (marker & 0x0F) + 1)
        when 0xA, 0xC
          length, start = length_and_pos(marker, pos)
          refs(start, length).map { |r| object(r) }
        when 0xD
          length, start = length_and_pos(marker, pos)
          keys   = refs(start, length)
          values = refs(start + length * @ref_size, length)
          Hash[keys.zip(values).map { |k, v| [ object(k), object(v) ] }]
        else
          raise ParseError, "Unknown object type 0x#{marker.to_s(16)} in binary property list"
        end
      end
    end

    class XMLParser
      ENTITIES = { 'lt' => '<', 'gt' => '>', 'amp' => '&', 'quot' => '"', 'apos' => "'" }

      def initialize(xml)
        @s = StringScanner.new(xml)
      end

      def parse
        skip_misc
        if @s.scan(/<plist\b[^>]*\/>/)
          return nil
        elsif @s.scan(/<plist\b[^>]*>/)
          skip_misc
          res = @s.check(/<\/plist>/) ? nil : value
          skip_misc
          expect(/<\/plist>/)
          res
        else
          value
        end
      end

      private

      def skip_misc
        loop do
          @s.skip(/\s+/)
          break unless @s.skip(/<\?.*?\?>/m) || @s.skip(/<!--.*?-->/m) || @s.skip(/<!DOCTYPE[^>]*>/m)
        end
      end

      def expect(re)
        @s.scan(re) or raise ParseError, "Expected #{re.source} at offset #{@s.pos}"
      end

      def text_until(tag)
        str = @s.scan_until(/<\/#{tag}>/) or raise ParseError, "Unterminated <#{tag}>"
        unescape(str[0...-(tag.length + 3)])
      end

      def unescape(str)
        str.gsub(/&(#x\h+|#\d+|\w+);/) do
          ent = $1
          if ent.start_with?('#x') then [ ent[2..-1].hex ].pack('U')
          elsif ent.start_with?('#') then [ ent[1..-1].to_i ].pack('U')
          else ENTITIES.fetch(ent) { "&#{ent};" }
          end
        end
      end

      def value
        skip_misc
        if    @s.scan(/<dict\s*\/>/)    then {}
        elsif @s.scan(/<dict\s*>/)      then dict
        elsif @s.scan(/<array\s*\/>/)   then []
        elsif @s.scan(/<array\s*>/)     then array
        elsif @s.scan(/<string\s*\/>/)  then ''
        elsif @s.scan(/<string\s*>/)    then text_until('string')
        elsif @s.scan(/<integer\s*>/)   then text_until('integer').strip.to_i
        elsif @s.scan(/<real\s*>/)      then text_until('real').strip.to_f
        elsif @s.scan(/<true\s*\/>/)    then true
        elsif @s.scan(/<false\s*\/>/)   then false
        elsif @s.scan(/<date\s*>/)      then Time.iso8601(text_until('date').strip)
        elsif @s.scan(/<data\s*\/>/)    then blob(String.new)
        elsif @s.scan(/<data\s*>/)      then blob(text_until('data').unpack('m').first)
        else raise ParseError, "Unexpected content at offset #{@s.pos}: #{@s.peek(20).inspect}"
        end
      end

      def dict
        res = {}
        loop do
          skip_misc
          break if @s.scan(/<\/dict>/)
          key = @s.scan(/<key\s*\/>/) ? '' : (expect(/<key\s*>/) && text_until('key'))
          res[key] = value
        end
        res
      end

      def array
        res = []
        loop do
          skip_misc
          break if @s.scan(/<\/array>/)
          res << value
        end
        res
      end

      def blob(str)
        str.blob = true
        str
      end
    end

    class XMLGenerator
      def document(obj)
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" \
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" \
        "<plist version=\"1.0\">\n" + element(obj, 0) + "</plist>\n"
      end

      def element(obj, level)
        indent = "\t" * level
        case obj
        when Hash
          return "#{indent}<dict/>\n" if obj.empty?
          res = "#{indent}<dict>\n"
          obj.each do |key, value|
            res << "#{indent}\t<key>#{escape(key.to_s)}</key>\n" << element(value, level + 1)
          end
          res << "#{indent}</dict>\n"
        when Array
          return "#{indent}<array/>\n" if obj.empty?
          res = "#{indent}<array>\n"
          obj.each { |value| res << element(value, level + 1) }
          res << "#{indent}</array>\n"
        when String
          if obj.blob?
            "#{indent}<data>\n" + [ obj ].pack('m').lines.map { |line| "#{indent}#{line}" }.join + "#{indent}</data>\n"
          else
            "#{indent}<string>#{escape(obj)}</string>\n"
          end
        when Symbol    then "#{indent}<string>#{escape(obj.to_s)}</string>\n"
        when Integer   then "#{indent}<integer>#{obj}</integer>\n"
        when Float     then "#{indent}<real>#{obj}</real>\n"
        when true      then "#{indent}<true/>\n"
        when false     then "#{indent}<false/>\n"
        when Time      then "#{indent}<date>#{obj.dup.utc.iso8601}</date>\n"
        when Date      then "#{indent}<date>#{obj.to_time.utc.iso8601}</date>\n"
        when nil       then "#{indent}<string></string>\n"
        else
          raise ArgumentError, "Unable to convert #{obj.class} to a property list"
        end
      end

      def escape(str)
        str.to_s.gsub(/[&<>]/, '&' => '&amp;', '<' => '&lt;', '>' => '&gt;')
      end
    end

    class OpenStepGenerator
      def generate(obj, level)
        indent = "\t" * level
        case obj
        when Hash
          return '{ }' if obj.empty?
          "{\n" + obj.map { |key, value| "#{indent}\t#{quote(key.to_s)} = #{generate(value, level + 1)};\n" }.join + "#{indent}}"
        when Array
          return '( )' if obj.empty?
          "(\n" + obj.map { |value| "#{indent}\t#{generate(value, level + 1)}" }.join(",\n") + "\n#{indent})"
        when String
          obj.blob? ? '<' + obj.unpack('H*').first + '>' : quote(obj)
        when true      then '1'
        when false     then '0'
        when Time      then quote(obj.dup.utc.iso8601)
        when nil       then '""'
        else quote(obj.to_s)
        end
      end

      def quote(str)
        return str if str =~ /\A[\w.\/]+\z/
        '"' + str.gsub(/[\\"]/) { |ch| "\\#{ch}" }.gsub("\n", '\n').gsub("\t", '\t') + '"'
      end
    end
  end
end

class String
  attr_writer :blob

  def blob?
    instance_variable_defined?(:@blob) && @blob
  end
end

class Object
  def to_plist(format = :xml1)
    OSX::PropertyList.generate(self, format)
  end
end
