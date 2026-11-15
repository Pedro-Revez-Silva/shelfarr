# frozen_string_literal: true

module Migration
  module Packaging
    module Elf
      MACHINES = { 0x3e => "amd64", 0xb7 => "arm64" }.freeze
      PT_INTERP = 3

      Description = Data.define(:architecture, :bits, :little_endian, :static)

      module_function

      def describe(path)
        header = File.binread(path, 64)
        raise ArgumentError, "not an ELF file" unless header&.start_with?("\x7FELF".b)

        offset = header[32, 8].unpack1("Q<")
        size = header[54, 2].unpack1("v")
        count = header[56, 2].unpack1("v")
        types = File.open(path, "rb") { |file| Array.new(count) { |index| file.seek(offset + (index * size)); file.read(4).unpack1("V") } }
        Description.new(architecture: MACHINES.fetch(header[18, 2].unpack1("v"), "other"), bits: header.getbyte(4) == 2 ? 64 : 32,
                        little_endian: header.getbyte(5) == 1, static: !types.include?(PT_INTERP))
      end
    end
  end
end
