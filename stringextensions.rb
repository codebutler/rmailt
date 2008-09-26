class String
  def replace_last_char(char, replacement)
    i = self.rindex(char)
    r = self[0..i-1]
    r << replacement
    r << self[i+1..-1]
    r
  end
end
