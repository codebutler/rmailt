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


PID_FILE = '/var/run/rmailt/rmailt.pid'

begin
require 'rubygems'
rescue LoadError
end

require 'optparse'
require 'syslog'
require 'syslog_logger'
require 'tmail'
require 'tlsmail'
require 'yaml'
require 'dm-core'
require 'yaml'
require 'xmpp4r'
require 'xmpp4r/discovery'
require 'xmpp4r/rexmladdons'
require 'net/imap'

require 'rmailt/imapextensions'
require 'rmailt/imap_watcher'
require 'rmailt/stringextensions'
require 'rmailt/register'
require 'rmailt/gateway'
require 'rmailt/user'
require 'rmailt/daemonize'

include Daemonize

include Jabber::Discovery
include Jabber::Dataforms

class RMailT
  attr_reader :config
  
  def initialize()
    # Parse command line options
    @options = { :config => '/etc/rmailt.yml' }
    OptionParser.new do |opts|
      opts.banner = "Usage: rmailt [options]"
      opts.on("--debug", "Enable debug output") do |d|
        @options[:debug] = d
      end    
      opts.on("-d", "--daemon", "Run as a background dameon") do |d|
        @options[:daemon] = d
      end    
      opts.on("--config CONFIGFILE", "Specify configuration file (defaults to /etc/rmailt.yml)") do |c|
        @options[:config] = c
      end
    end.parse!

    # Set up debug logging if enabled
    if @options[:debug] == true
      Jabber::debug = true
      Net::IMAP.debug = true
      DataMapper::Logger.new(STDOUT, :debug)
      Jabber.logger.info('Debug Enabled')
    end
    
    Jabber.logger.info('Initializing...')
  
    # Read configuration file
    @config = YAML::load_file(@options[:config])
    
    # Load users database
    db_path = File.join(@config[:data_dir], 'rmailt.db')
    DataMapper.setup(:default, "sqlite3:#{db_path}")
    User.auto_upgrade! # XXX This might not be safe!
    
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
        Jabber.logger.debug("New user registered! #{jid.bare}")
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
      elsif presence.type == nil
        if user
          Jabber.logger.debug("User is now online: #{presence.from.bare.to_s}")
          send_presence(user)
        end
      end
    end
    
    # Set up message handler
    @component.add_message_callback do |message|
      user = User.first(:jid => message.from.bare.to_s)
      if user
        if user.roster_items.include?(message.to.to_s)
          to_email = message.to.to_s
          to_email = to_email[0..to_email.rindex('@')-1].gsub('%','@')
          
          # Replace the last '@' with a '+'
          from_email = message.from.bare.to_s.replace_last_char('@', '+')
          from_email << "@#{@config[:jid]}"
          
          smtp_server = @config[:smtp_server]
          smtp_port   = @config[:smtp_port]
          helo        = @config[:jid]
          smtp_user   = @config[:smtp_user]
          smtp_pass   = @config[:smtp_pass]
          
          body = message.first_element_text('body')
          msg = "From: #{from_email}\r\nTo: #{to_email}\r\n\r\n#{body}"
          
          # XXX: This should be replaced by a worker thread/queue
          Thread.new do
            begin
              Net::SMTP.enable_tls(OpenSSL::SSL::VERIFY_NONE)
              Net::SMTP.start(smtp_server, smtp_port)  do |smtp|
                smtp.send_message(msg, from_email, [ to_email ])
              end
              Jabber.logger.debug("Email sent. From: #{from_email} To: #{to_email}")
            rescue Exception => ex
              Jabber.logger.error("ERROR WHILE SENDING MAIL! #{ex} #{ex.backtrace.join("\n")}")
              msg = Jabber::Message.new(message.from, "Sorry, an error has occured and the following message was not sent:\n\n#{msg}")
              msg.from = @config[:jid]
              msg.to = message.from
              @component.send(msg)
            end
          end
        else
          Jabber.logger.debug("NOT IN ROSTER !!!")
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
      
      Jabber.logger.debug("Received email from: #{from_email} to: #{to_email}")
      
      begin
        to_jid   = to_email[0..to_email.index('@')-1].replace_last_char('+', '@')
        from_jid = "#{from_email.gsub(/@/, '%')}@#{@config[:jid]}"

        Jabber.logger.debug("Received email from JIDs: #{from_jid} to: #{to_jid}")
        
        user = User.first(:jid => to_jid)
        if user
          if user.roster_items.include?(from_jid)
            # We have a message to send!
            msg = Jabber::Message.new(from_jid, body)
            msg.type = :chat
            msg.from = from_jid
            msg.to = to_jid
            @component.send(msg)
          else
            Jabber.logger.debug("#{from_jid} is not in #{to_jid} roster")
          end
        end
      rescue Exception => ex
        Jabber.logger.error("FAILED TO PARSE EMAIL!! #{to_email} #{ex}")
      end
      
      # Delete the mail
      true
    end
  end
  
  def start()
    # Become a daemon if requested
    if @options[:daemon] == true
      pid = daemonize()
      # Use syslog for logging
      Jabber.logger = SyslogLogger.new('rmailt')
      # Write out PID file.
      begin
        if File.file?(PID_FILE)
          Jabber.logger.fatal("#{PID_FILE} exists! Exiting!")
          exit 1
          return
        end
        File.open(PID_FILE, 'w') do |file|
          file.puts Process.pid
        end
      rescue Exception
        Jabber.logger.fatal("Failed to write #{PID_FILE}! Exiting.")
        exit 1
        return
      end
    end
  
    server = @config[:server]
    port   = @config[:port]
    secret = @config[:secret]
    
    Jabber.logger.info("Connecting to XMPP server (#{server}:#{port})")
    @component.connect(server, port)
    @component.auth(secret)

    @imap_watcher.start()

    Jabber.logger.info("Connected to XMPP server!")
     
    # Connected! 
    registered_users.each do |user|
      send_presence(user)
    end
    
  Jabber.logger.info('Started')
  Thread.stop()
  end
  
  private
  
  def registered_users
    User.all
  end
  
  def send_presence(user)
    # Make transport appear online
    presence = Jabber::Presence.new()
    presence.from = @config[:jid]
    presence.to = user.jid
    @component.send(presence)

    # Make all email contacts appear online!
    user.roster_items.each do |item|
      presence = Jabber::Presence.new()
      presence.from = item
      presence.to = user.jid
      @component.send(presence)
    end
  end
end
