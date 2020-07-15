module RubySMB
  module Dcerpc
    module Ndr

      # NDR Syntax
      UUID = '8a885d04-1ceb-11c9-9fe8-08002b104860'
      VER_MAJOR = 2
      VER_MINOR = 0


      # An NDR Conformant and Varying String representation as defined in
      # [Transfer Syntax NDR - Conformant and Varying Strings](http://pubs.opengroup.org/onlinepubs/9629399/chap14.htm#tagcjh_19_03_04_02)
      # The string elements are Stringz16 (unicode)
      class NdrString < BinData::Primitive
        endian :little

        uint32    :max_count
        uint32    :offset, initial_value: 0
        uint32    :actual_count
        stringz16 :str, read_length: -> { actual_count * 2 }, onlyif: -> { actual_count > 0 }

        def get
          self.actual_count == 0 ? 0 : self.str
        end

        def set(v)
          if v.is_a?(Integer) && v == 0
            self.str.clear
            self.actual_count = 0
          else
            self.str = v.to_s
            self.max_count = str.to_binary_s.size / 2 if self.max_count == 0
            self.actual_count = str.to_binary_s.size / 2 unless str.empty?
          end
        end

        def clear
          # Make sure #max_count and #offset are not cleared out
          self.str.clear
          self.actual_count.clear
        end

        def to_s
          self.str.to_s
        end
      end

      # An NDR Uni-dimensional Conformant Array of Bytes representation as defined in
      # [Transfer Syntax NDR - Uni-dimensional Conformant Arrays](https://pubs.opengroup.org/onlinepubs/9629399/chap14.htm#tagfcjh_26)
      class NdrLpByte < BinData::Primitive
        endian :little

        uint32 :max_count, value: -> { self.elements.size }
        array  :elements, type: :uint8, read_until: -> { index == self.max_count}, onlyif: -> { self.max_count > 0 }

        def get
          self.elements
        end

        def set(v)
          self.elements = v.to_ary
        end
      end

      # An NDR Uni-dimensional Conformant-varying Arrays of bytes representation as defined in:
      # [Transfer Syntax NDR - NDR Constructed Types](http://pubs.opengroup.org/onlinepubs/9629399/chap14.htm#tagcjh_19_03_03_04)
      class NdrByteArray < BinData::Primitive
        endian :little

        uint32 :max_count, initial_value: -> { actual_count }
        uint32 :offset, initial_value: 0
        uint32 :actual_count, initial_value: -> { bytes.size }
        array  :bytes, :type => :uint8, initial_length: -> { actual_count }

        def get
          self.bytes
        end

        def set(v)
          self.bytes = v.to_ary
        end
      end

      # An NDR Top-level Full Pointers representation as defined in
      # [Transfer Syntax NDR - Top-level Full Pointers](http://pubs.opengroup.org/onlinepubs/9629399/chap14.htm#tagcjh_19_03_11_01)
      # This class must be inherited and the subclass must have a #referent protperty
      class NdrTopLevelFullPointer < BinData::Primitive
        endian :little

        uint32 :referent_identifier, initial_value: 0x00020000

        def get
          is_a_null_pointer? ? 0 : self.referent
        end

        def set(v)
          if v.is_a?(Integer) && v == 0
            self.referent_identifier = 0
          else
            self.referent = v
          end
        end

        def is_a_null_pointer?
          self.referent_identifier == 0
        end
      end

      # A generic NDR structure
      class NdrStruct < BinData::Record

        def do_read(io)
          super(io)
          each_pair do |_name, field|
            case field
            when BinData::Array
              field.each do |element|
                next unless element.is_a?(NdrPointer)
                next if element.referent_id == 0
                pad = (4 - io.offset % 4) % 4
                io.seekbytes(pad) if pad > 0
                element.referent.do_read(io)
              end
            when NdrPointer
              next if field.referent_id == 0
              pad = (4 - io.offset % 4) % 4
              io.seekbytes(pad) if pad > 0
              field.referent.do_read(io)
            end
          end
        end

        def do_write(io)
          super(io)
          each_pair do |_name, field|
            case field
            when BinData::Array
              field.each do |element|
                next unless element.is_a?(NdrPointer)
                next if element.referent_id == 0
                pad = (4 - io.offset % 4) % 4
                io.writebytes("\x00" * pad + element.referent.to_binary_s)
              end
            when NdrPointer
              next if field.referent_id == 0
              pad = (4 - io.offset % 4) % 4
              io.writebytes("\x00" * pad + field.referent.to_binary_s)
            end
          end
        end
      end

      # A generic NDR pointer
      class NdrPointer < BinData::Primitive
        endian :little
        uint32 :referent_id, initial_value: 0

        def do_read(io)
          self.referent_id.do_read(io)
        end

        def do_write(io)
          self.referent_id.do_write(io)
        end

        def set(v)
          if v == :null
            self.referent_id = 0
          elsif self.referent_id == 0
            self.referent_id = rand(0xFFFFFFFF)
          end
        end

        def get
          self.referent_id
        end

        def process_referent?
          current_parent = parent
          loop do
            return true unless current_parent
            return false if current_parent.is_a?(NdrStruct)
            current_parent = current_parent.parent
          end
        end
      end

      # A pointer to a NdrString structure
      class NdrLpStr < NdrPointer
        endian :little

        ndr_string :referent, onlyif: -> { self.referent_id != 0 }

        def do_read(io)
          super(io)
          if process_referent?
            self.referent.do_read(io) unless self.referent_id == 0
          end
        end

        def do_write(io)
          super(io)
          if process_referent?
            self.referent.do_write(io) unless self.referent_id == 0
          end
        end

        def set(v)
          if v == :null
            self.referent.clear
          else
            self.referent.set(v)
          end
          super(v)
        end

        def get
          if self.referent_id == 0
            :null
          else
            self.referent
          end
        end

      end

      # An NDR Context Handle representation as defined in
      # [IDL Data Type Declarations - Basic Type Declarations](http://pubs.opengroup.org/onlinepubs/9629399/apdxn.htm#tagcjh_34_01)
      class NdrContextHandle < BinData::Primitive
        endian :little
        uint32 :context_handle_attributes
        uuid   :context_handle_uuid

        def get
          {:context_handle_attributes => context_handle_attributes, :context_handle_uuid => context_handle_uuid}
        end

        def set(handle)
          if handle.is_a?(Hash)
            handle = handle
            self.context_handle_attributes = handle[:context_handle_attributes]
            self.context_handle_uuid = handle[:context_handle_uuid]
          elsif handle.is_a?(NdrContextHandle)
            read(handle.to_binary_s)
          else
            read(handle.to_s)
          end
        end
      end

      class NdrLpDword < NdrPointer
        endian :little

        uint32 :referent, onlyif: -> { self.referent_id != 0 }

        def do_read(io)
          super(io)
          if process_referent?
            self.referent.do_read(io) unless self.referent_id == 0
          end
        end

        def do_write(io)
          super(io)
          if process_referent?
            self.referent.do_write(io) unless self.referent_id == 0
          end
        end

        def set(v)
          if v == :null
            self.referent.clear
          else
            self.referent = v
          end
          super(v)
        end

        def get
          if self.referent_id == 0
            :null
          else
            self.referent
          end
        end
      end

      class NdrStringPtrsw < NdrStruct
        endian :little

        uint32 :max_count, value: -> { self.elements.size }
        array  :elements, type: :ndr_lp_str, read_until: -> { index == self.max_count - 1 }, onlyif: -> { self.max_count > 0 }

        def get
          self.elements
        end

        def set(v)
          self.elements = v.to_ary
        end

        def do_num_bytes
          to_binary_s.size
        end
      end

      class NdrLpStringPtrsw < NdrPointer
        endian :little

        ndr_string_ptrsw :referent, onlyif: -> { self.referent_id != 0 }

        def do_read(io)
          super(io)
          if process_referent?
            self.referent.do_read(io) unless self.referent_id == 0
          end
        end

        def do_write(io)
          super(io)
          if process_referent?
            self.referent.do_write(io) unless self.referent_id == 0
          end
        end

        def set(v)
          if v == :null
            self.referent.clear
          else
            self.referent.elements = v.elements.to_ary
          end
          super(v)
        end

        def get
          if self.referent_id == 0
            :null
          else
            self.referent
          end
        end
      end

      # A pointer to an NDR Uni-dimensional Conformant-varying Arrays of bytes
      class NdrLpByteArray < NdrPointer
        endian :little

        ndr_byte_array :referent, onlyif: -> { self.referent_id != 0 }

        def do_read(io)
          super(io)
          if process_referent?
            self.referent.do_read(io) unless self.referent_id == 0
          end
        end

        def do_write(io)
          super(io)
          if process_referent?
            self.referent.do_write(io) unless self.referent_id == 0
          end
        end

        def set(v)
          if v == :null
            self.referent.clear
          else
            self.referent = v.is_a?(NdrLpByteArray) ? v.referent : v
          end
          super(v)
        end

        def get
          if self.referent_id == 0
            :null
          else
            self.referent
          end
        end

      end

      # A pointer to a Windows FILETIME structure
      class NdrLpFileTime < NdrTopLevelFullPointer
        endian :little

        file_time :referent, onlyif: -> { !is_a_null_pointer? }
      end
    end
  end
end
