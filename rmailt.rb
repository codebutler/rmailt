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

require 'rubygems'
require 'tmail'
require 'tlsmail'
require 'yaml'
require 'dm-core'
require 'yaml'
require 'xmpp4r'
require 'xmpp4r/discovery'
require 'xmpp4r/rexmladdons'
require 'register'
require 'gateway'
require 'user'
require 'net/imap'
require 'imapextensions'
require 'imap_watcher'

include Jabber::Discovery
include Jabber::Dataforms

class RMailT
  attr_reader :config
  
  def initialize()
    # Read configuration file
    @config = YAML::load_file('config.yml')
    
    # Load users database
    DataMapper::Logger.new(STDOUT, 0)
    DataMapper.setup(:default, 'sqlite3:rmailt.db')
    # User.auto_migrate!
    
    # Create component
    jid = @config[:jid]
    @component = Jabber::Component.new(jid)
    
    # Create service discovery responder
    @disco_responder = Jabber::Discovery::Responder.new(@component)
    @disco_responder.identities = [
      Identity.new('gateway', 'SMTP Transport', 'smtp')    
    ]
    @disco_responder.add_features([
      'http://jabber.org/protocol/disco',
      'jabber:iq:register'
    ])
    
    # Create registration responder
    @register_responder = Jabber::Register::Responder.new(@component)
    @register_responder.instructions = 'A password is required to use this service.'
    @register_responder.add_field(:password, true) do |value|
      value == @config[:access_password]
    end
    @register_responder.add_registered_callback() do |jid|
      user = User.first(:jid => jid.bare.to_s)
      if user.nil?
        puts "New user registered! #{jid.bare}"
        user = User.new(:jid => jid.bare.to_s)
        user.roster_items = []
        user.save
      end
      # Send service online presence
      p = Jabber::Presence.new()
      p.from = @config[:jid]
      p.to = jid.bare
      @component.send(p)
    end
    
    # Create gateway responder
    @gateway_responder = Jabber::Gateway::Responder.new(@component) do |email|
       "#{email.gsub(/@/,'%')}@#{@config[:jid]}"
    end
    @gateway_responder.description = "Please enter your friend's email address"
    @gateway_responder.prompt = "Email Address"
    
    # Set up presence management
    @component.add_presence_callback do |presence|
      user = User.first(:jid => presence.from.bare.to_s)
      if [:subscribe, :subscribed].include?(presence.type)
        if user
          unless user.roster_items.include?(presence.to.to_s)
            # New email address!
            user.roster_items << presence.to.to_s
            user.save
            # Send subscribe request
            req = Jabber::Presence.new()
            req.from = presence.to
            req.to = presence.from
            req.type = :subscribe
            @component.send(req)
          end
        
          if presence.type == :subscribe
            # A user is adding an email address to their roster
            # Approve the subscription
            answer = presence.answer(false)
            answer.type = :subscribed
            @component.send(answer)
          end
        
          # Appear "online"
          p = presence.answer(false)
          @component.send(p)  
        else
          msg = Jabber::Message.new(presence.from, 'Sorry, you must be registered to use this service.')
          msg.from = @config[:jid]
          msg.to = presence.from
          @component.send(msg)
        end          
      elsif [:unsubscribe, :unsubscribed].include?(presence.type)
        # Unsubscribe
        if user
          user.roster_items.delete(presence.to.to_s)
          user.save
        end
      end
    end
    
    # Set up message handler
    @component.add_message_callback do |message|
      user = User.first(:jid => message.from.bare.to_s)
      if user
        if user.roster_items.include?(message.to.to_s)
          to_email = message.to.to_s
          to_email = to_email[0..to_email.index('@')-1].gsub('%','@')
          
          from_email = "#{message.from.bare.to_s.gsub('@', '===')}@#{@config[:jid]}"
          
          smtp_server = @config[:smtp_server]
          smtp_port   = @config[:smtp_port]
          helo        = @config[:jid]
          smtp_user   = @config[:smtp_user]
          smtp_pass   = @config[:smtp_pass]
          
          body = message.first_element_text('body')
          msg = "From: #{from_email}\r\nTo: #{to_email}\r\n\r\n#{body}"
          
          Thread.new do
            begin
              Net::SMTP.enable_tls(OpenSSL::SSL::VERIFY_NONE)
              Net::SMTP.start(smtp_server, smtp_port)  do |smtp|
                smtp.send_message(msg, from_email, [ to_email ])
              end
            rescue Exception => ex
              Jabber::debuglog("ERROR WHILE SENDING MAIL! #{ex} #{ex.backtrace.join("\n")}")
              msg = Jabber::Message.new(message.from, "Sorry, an error has occured and the following message was not sent:\n\n#{msg}")
              msg.from = @config[:jid]
              msg.to = message.from
              @component.send(msg)
            end
          end
        else
          puts "NOT IN ROSTER !!!"
        end
      else
        msg = Jabber::Message.new(message.from, 'Sorry, you must be registered to use this service.')
        msg.type = :chat
        msg.from = @config[:jid]
        msg.to = message.from
        @component.send(msg)
      end
    end
    
    # Set up IMAP watcher
    @imap_watcher = IMAPWatcher.new(@config[:imap_server], @config[:imap_login], @config[:imap_pass])
    @imap_watcher.add_message_handler do |raw|
      mail = TMail::Mail.parse(raw)
      from_email = mail.from.first
      to_email   = mail.to.first
      body       = mail.body
      
      Jabber::debuglog("Received email from: #{from_email} to: #{to_email}")
      
      begin
        to_jid     = to_email[0..to_email.index('@')-1].gsub(/===/, '@')
        from_jid   = "#{from_email.gsub(/@/, '%')}@#{@config[:jid]}"
        
        user = User.first(:jid => to_jid)
        if user
          if user.roster_items.include?(from_jid)
            # We have a message to send!
            msg = Jabber::Message.new(from_jid, body)
            msg.type = :chat
            msg.from = from_jid
            msg.to = to_jid
            @component.send(msg)
          end
        end
      rescue Exception => ex
        puts "FAILED TO PARSE EMAIL!! #{to_email} #{ex}"
      end
      
      # Delete the mail
      true
    end
  end
  
  def start()
    server = @config[:server]
    port   = @config[:port]
    secret = @config[:secret]
    
    Jabber::debuglog("Connecting to server (#{server}:#{port})")
    @component.connect(server, port)
    @component.auth(secret)
    
    @imap_watcher.start()
  end
  
  private
  
  def registered_users
    User.all
  end
end

# Set up logging
Jabber::debug = true

# Start the app!
$app = RMailT.new
$app.start()
Thread.stop()
