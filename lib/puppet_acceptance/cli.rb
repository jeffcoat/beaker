module PuppetAcceptance
  class CLI
    def initialize
      @options = PuppetAcceptance::Options.parse_args
      @logger = PuppetAcceptance::Logger.new(@options)
      @options[:logger] = @logger

      if @options[:config] then
        @logger.debug "Using Config #{@options[:config]}"
      else
        report_and_raise(@logger, RuntimeError.new("Argh!  There is no default for Config, specify one (-c or --config)!"), "CLI: initialize") 
      end

      @config = PuppetAcceptance::TestConfig.new(@options[:config], @options)

      #add additional paths to the LOAD_PATH
      if not @options[:load_path].empty?
        @options[:load_path].each do |path|
          $LOAD_PATH << File.expand_path(path)
        end
      end
      if (@options[:helper])
        require File.expand_path(@options[:helper])
      end

      @hosts =  []
      @network_manager = PuppetAcceptance::NetworkManager.new(@config, @options, @logger)
      @hosts = @network_manager.provision

    end

    def execute!
      @ntp_controller = PuppetAcceptance::Utils::NTPControl.new(@options, @hosts)
      @setup = PuppetAcceptance::Utils::SetupHelper.new(@options, @hosts)
      @repo_controller = PuppetAcceptance::Utils::RepoControl.new(@options, @hosts)

      setup_steps = [[:timesync, "sync time on vms", Proc.new {@ntp_controller.timesync}],
                     [:root_keys, "sync keys to vms" , Proc.new {@setup.sync_root_keys}],
                     [:repo_proxy, "set repo proxy", Proc.new {@repo_controller.proxy_config}],
                     [:extra_repos, "add repo", Proc.new {@repo_controller.add_repos}],
                     [:add_master_entry, "update /etc/hosts on master with master's ip", Proc.new {@setup.add_master_entry}],
                     [:set_rvm_of_ruby, "set RVM of ruby", Proc.new {@setup.set_rvm_of_ruby}]]
      
      begin
        trap(:INT) do
          @logger.warn "Interrupt received; exiting..."
          exit(1)
        end
        #setup phase
        setup_steps.each do |step| 
          if (not @options.has_key?(step[0])) or @options[step[0]]
            @logger.notify ""
            @logger.notify "Setup: #{step[1]}"
            step[2].call
          end
        end
        #pre acceptance  phase
        run_suite('pre-suite', pre_suite_options, :fail_fast)
        #testing phase
        begin
          run_suite('acceptance', @options) unless @options[:installonly]
        #post acceptance phase
        rescue => e
          #post acceptance on failure
          #if we error then run the post suite as long as we aren't in fail-stop mode
          run_suite('post-suite', post_suite_options) unless @options[:fail_mode] == "stop"
          raise e
        else
          #post acceptance on success
          run_suite('post-suite', post_suite_options)
        end
      #cleanup phase
      rescue => e
        #cleanup on error
        #only do cleanup if we aren't in fail-stop mode
        @logger.notify "Cleanup: cleaning up after failed run"
        if @options[:fail_mode] != "stop"
          @network_manager.cleanup
        end
        raise "Failed to execute tests!"
      else
        #cleanup on success
        @logger.notify "Cleanup: cleaning up after successful run"
        @network_manager.cleanup
      end
    end

    def run_suite(name, options, failure_strategy = false)
      if (options[:tests].empty?)
        @logger.notify("No tests to run for suite '#{name}'")
        return
      end
      PuppetAcceptance::TestSuite.new(
        name, @hosts, options, @config, failure_strategy
      ).run_and_raise_on_failure
    end

    def pre_suite_options
      @options.merge({
        :random => false,
        :tests => @options[:pre_suite] })
    end
    def post_suite_options
      @options.merge({
        :random => false,
        :tests => @options[:post_suite] })
    end

  end
end
