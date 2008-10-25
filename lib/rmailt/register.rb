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

# Implenentation of XEP-0077: In-Band Registration
# http://www.xmpp.org/extensions/xep-0077.html

module Jabber
  module Register

    NS_REGISTER =  'jabber:iq:register'
  
    ALLOWED_FIELDS = [ 
      :username, :nick, :password, :name, :first, :last, :email, :address,
      :city, :state, :zip, :phone, :url, :date, :misc, :text, :key 
    ]
    
    class Responder
      attr_accessor :instructions
      
      def initialize(stream)
        @stream = stream
        @fields = []
        @registered_callbacks = []
        
        @stream.add_iq_callback() do |iq|
          if iq.query.kind_of?(IqQueryRegister)
            if iq.type == :get
              # New registration request, reply with fields
              answer = iq.answer(false)
              answer.type = :result
              query = answer.add(IqQueryRegister.new)
              unless instructions.nil?
                query.add(Field.new(:instructions, @instructions))
              end
              @fields.each do |field_info|
                name, required, validator = *field_info
                query.add(Field.new(name))
              end
              @stream.send(answer)
            elsif iq.type == :set
              # Received registration response
              iq.query.each do |field|
                name  = field.name
                value = field.text
                validator = @fields.assoc(name.to_sym)[2]
                if !validator.call(value)
                  # Reply with registration error
                  answer = iq.answer(true)
                  answer.type = :error
                  answer.add(Jabber::ErrorResponse.new('not-acceptable'))
                  @stream.send(answer)
                  return
                end
              end
              
              # XXX: Check for missing required fields
              
              # Let them know that all looks good!
              answer = iq.answer(false)
              answer.type = :result
              @stream.send(answer)
              
              # Fire off callbacks
              @registered_callbacks.each do |cb|
                cb.call(iq.from)
              end
            end
          end
        end
      end
      
      def add_field(name, required, &validator)
        if ALLOWED_FIELDS.include?(name)
          @fields << [ name, required, validator ]
        else
          raise "Unknown field name"
        end
      end
      
      # Add a callback that will be fired when a user is sucessfully
      # registered.
      def add_registered_callback(&cb)
        @registered_callbacks << cb
      end
    end
  end
  
  class IqQueryRegister < IqQuery
    name_xmlns 'query', Jabber::Register::NS_REGISTER
  end
  
  class Field < REXML::Element
    def initialize(name, value=nil)
      super(name.to_s)
      self.text = value
    end
  end
end
