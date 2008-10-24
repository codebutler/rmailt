# rMailt - An XMPP<->Email transport written in ruby.
# Copyright (C) 2008  Eric Butler <eric@extremeboredom.net>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

class IMAPWatcher
  def initialize(server, login, pass)
    @server = server
    @login  = login
    @pass   = pass
    @is_idle = false
    @message_handlers = []
    
    # Set up the IMAP worker
    @resource = ConditionVariable.new
    @mutex = Mutex.new
    Thread.new do
      begin
        while true
          @mutex.synchronize {
            @resource.wait(@mutex)
          }
          if @is_idle == true
            @imap.done()
            @is_idle = false
          end
          @imap.search('ALL').each do |message_id|
            raw = @imap.fetch(message_id, 'BODY[]')[0].attr['BODY[]']
            @message_handlers.each do |handler|
              if handler.call(raw) == true
                # Delete the message!
                @imap.store(message_id, "+FLAGS", [:Deleted])
              end
            end
          end
          @imap.expunge()
          @imap.idle()
          @is_idle = true
        end
      rescue Exception => ex
        Jabber.logger.fatal("ERROR IN IMAP WORKER THREAD: #{ex}")
      end
    end
  end
  
  def add_message_handler(&handler)
    @message_handlers << handler
  end
  
  def start() 
    while true
      imap_thread = Thread.new do
        begin
          Jabber.logger.info("IMAP connecting to #{@server}:#{993}")
          @imap = Net::IMAP.new(@server, 993, true)
          @imap.authenticate('LOGIN', @login, @pass)
          @imap.add_response_handler do |resp|
            if resp.kind_of?(Net::IMAP::UntaggedResponse) and resp.name == "EXISTS"
              count = resp.data
              Jabber::debuglog("Mailbox now has #{count} messages")
              if count > 0
                @mutex.synchronize {
                  @resource.broadcast()
                }
              end
            elsif resp.is_a?(Net::IMAP::TaggedResponse) and resp.name == "BAD"
              Jabber.logger.error("IMAP BAD: #{resp.data.text}")
            end
          end
          
          Jabber.logger.info("IMAP connected!")
          
          @imap.select('inbox')
          
          @mutex.synchronize {
            if @is_idle == false
              @imap.idle()
              @is_idle = true
            end
          }
          
          # Exception block will still be called if there is an exception.
          Thread.stop()
           
        rescue Exception => ex
          if ex.is_a?(Net::IMAP::ByeResponseError)
            Jabber.logger.error("IMAP disconnected. Will reconnect in 5 seconds...")
          elsif ex.is_a?(Errno::ECONNREFUSED)
            Jabber.logger.error("IMAP connection refused! Will reconnect in 5 seconds...")
          else
            # Something bad happened, die horribly!
            Jabber::logger.fatal(ex)
            Process.exit!
          end
        end
        
        @imap = nil
        @is_idle = false
      end
      
      imap_thread.join()
      imap_thread = nil
      
      sleep(5)
    end
  end
end
