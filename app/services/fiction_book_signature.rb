class FictionBookSignature
  MAX_BYTES = 4096
  ROOT = /\A(?:[ \t\r\n]++|<\?.*?\?>|<!--.*?-->)*+<FictionBook(?=[ \t\r\n\/>])/mn

  def self.matches?(header)
    text = header.to_s.b
    encoding = case text.byteslice(0, 2)
    when "\xFF\xFE".b then Encoding::UTF_16LE
    when "\xFE\xFF".b then Encoding::UTF_16BE
    end

    if encoding
      text = text.byteslice(2..).encode(Encoding::UTF_8, encoding, invalid: :replace, undef: :replace).b
    else
      text = text.delete_prefix("\xEF\xBB\xBF".b)
    end

    ROOT.match?(text)
  end
end
