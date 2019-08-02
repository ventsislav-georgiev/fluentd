#
# Fluentd
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

require 'fluent/plugin'
require 'fluent/plugin/service_discovery/discovery_message'

module Fluent
  module Plugin
    class ServiceDiscoveryManager
      def initialize(load_balancer:, log:, custom_build_method: nil)
        @log = log
        @load_balancer = load_balancer
        @custom_build_method = custom_build_method

        @discoveries = []
        @services = {}
        @draining_services = {}
        @queue = Queue.new
        @need_timer = false
      end

      attr_reader :need_timer

      def configure(opts)
        opts.each do |opt|
          sd = Fluent::Plugin.new_sd(opt[:type])
          sd.configure(opt[:conf])

          sd.services.each do |s|
            @services[s.discovery_id] = build_node(s)
          end
          @discoveries << sd

          if !@need_timer && opt[:type] != :static
            @need_timer = true
          end
        end

        rebalance
      end

      def start
        @discoveries.each do |d|
          d.start(@queue)
        end
      end

      def run_once
        # Don't care race in this loop intentionally
        s = @queue.size

        if s == 0
          return
        end

        s.times do
          msg = @queue.pop

          unless msg.is_a?(Fluent::Plugin::ServiceDiscovery::DiscoveryMessage)
            @log.warn("BUG: #{msg}")
            next
          end
          handle_message(msg)
        end

        rebalance
      end

      def rebalance
        @load_balancer.rebuild_weight_array(services)
      end

      def select_node(&block)
        @load_balancer.select_healthy_node(&block)
      end

      def services
        @services.values
      end

      private

      def handle_message(msg)
        service = msg.service

        case msg.type
        when :service_in
          @log.info("service_in")
          @services[service.discovery_id] = build_node(service)
        when :service_out
          @log.info("service_out")

          if (s = @services.delete(service.discovery_id))
            @draining_services[service.discovery_id] = s
          else
            @log.warn("Not found service: #{service}")
          end
        else
          @log.error("BUG: unknow message type: #{msg.type}")
        end
      end

      def build_node(n)
        @custom_build_method ? @custom_build_method.call(n) : n
      end
    end
  end
end
