#From http://www.ruby-forum.com/topic/50828
class Net::IMAP
   def idle
     cmd = "IDLE"
     synchronize do
       tag = generate_tag
       put_string(tag + " " + cmd)
       put_string(CRLF)
     end
   end
   def done
     cmd = "DONE"
     synchronize do
       put_string(cmd)
       put_string(CRLF)
     end
   end
end
