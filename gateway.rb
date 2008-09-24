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

# Implementation of XEP-0100: Gateway Interaction
# http://www.xmpp.org/extensions/xep-0100.html

module Jabber
  module Gateway

    NS_GATEWAY =  'jabber:iq:gateway'
    
    class Responder
      attr_accessor :description
      attr_accessor :prompt
      
      def initialize(stream, &format_func)
        @stream = stream
        @format_func = format_func
          
        @stream.add_iq_callback() do |iq|
          if iq.query.kind_of?(IqQueryGateway)
            if iq.type == :get
              # Client is requesting fields
              answer = iq.answer(false)
              answer.type = :result
              query = answer.add(IqQueryGateway.new)
              query.desc = @description
              query.prompt = @prompt
              @stream.send(answer)
            elsif iq.type == :set
              # Client is requesting full JID
              email = iq.query.prompt
              jid = @format_func.call(email)
              answer = iq.answer(false)
              answer.type = :result
              query = answer.add(IqQueryGateway.new)
              query.jid = jid
              @stream.send(answer)
            end
          end
        end
      end
    end
   
    class IqQueryGateway < IqQuery
      name_xmlns 'query', Jabber::Gateway::NS_GATEWAY
      
      def desc
        first_element_text('desc')
      end
      
      def desc=(new_desc)
        replace_element_text('desc', new_desc)
      end
      
      def prompt
        first_element_text('prompt')
      end
      
      def prompt=(new_prompt)
        replace_element_text('prompt', new_prompt)
      end
      
      def jid
        first_element_text('jid')
      end
      
      def jid=(new_prompt)
        replace_element_text('jid', new_prompt)
      end
    end
    
  end
end
