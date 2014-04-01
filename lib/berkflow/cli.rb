require 'berkflow'
require 'thor'
require 'solve'
require 'tempfile'
require 'fileutils'

module Berkflow
  class Cli < Thor
    def initialize(*args)
      super(*args)

      if @options[:verbose]
        Ridley.logger.level = ::Logger::INFO
      end

      if @options[:debug]
        Ridley.logger.level = ::Logger::DEBUG
      end
    end

    namespace "berkflow"

    map "up" => :upgrade

    class_option :verbose,
      type: :boolean,
      desc: "Output verbose information",
      aliases: "-v",
      default: false
    class_option :debug,
      type: :boolean,
      desc: "Output debug information",
      aliases: "-d",
      default: false
    class_option :ssh_user,
      type: :string,
      desc: "SSH user to execute commands as",
      aliases: "-u",
      default: ENV["USER"]
    class_option :ssh_password,
      type: :string,
      desc: "Perform SSH authentication with the given password",
      aliases: "-p",
      default: nil
    class_option :ssh_key,
      type: :string,
      desc: "Perform SSH authentication with the given key",
      aliases: "-P",
      default: nil

    method_option :sudo,
      type: :boolean,
      desc: "Execute with sudo",
      default: false
    desc "exec ENV CMD", "execute an arbitrary shell command on all nodes in an environment."
    def exec(environment, command)
      env = find_environment!(environment)

      say "Discovering nodes in #{environment}..."
      nodes = find_nodes(environment)

      if nodes.empty?
        say "No nodes in #{environment}. Done."
        exit(0)
      end

      say "Executing command on #{nodes.length} nodes..."
      success, failures, out = handle_results nodes.map { |node| ridley.node.run(node.public_hostname, command) }

      unless success.empty?
        say "Successfully executed command on #{success.length} nodes"
      end

      unless failures.empty?
        error "Failed to execute command on #{failures.length} nodes"
      end

      say "Done. See #{out} for logs."
      failures.empty? ? exit(0) : exit(1)
    end

    desc "run_chef ENV", "run chef on all nodes in the given environment."
    def run_chef(environment)
      env = find_environment!(environment)

      say "Discovering nodes in #{environment}..."
      nodes = find_nodes(environment)

      if nodes.empty?
        say "No nodes in #{environment}. Done."
        exit(0)
      end

      say "Running Chef Client on #{nodes.length} nodes..."
      success, failures, out = handle_results nodes.map { |node| ridley.node.chef_run(node.public_hostname) }

      unless success.empty?
        say "Successfully ran Chef Client on #{success.length} nodes"
      end

      unless failures.empty?
        error "Failed to run Chef Client on #{failures.length} nodes"
      end

      say "Done. See #{out} for logs."
      failures.empty? ? exit(0) : exit(1)
    end

    desc "upgrade ENV APP VERSION", "upgrade an environment to a specific application version."
    def upgrade(environment, application, version)
      version  = sanitize_version(version)
      env      = find_environment!(environment)
      cookbook = find_cookbook!(application, version)

      file = Tempfile.new("berkflow")
      unless contents = cookbook.download_file(:root_file, Berkshelf::Lockfile::DEFAULT_FILENAME, file.path)
        error "#{application} (#{version}) did not contain a Berksfile.lock"
        exit(1)
      end

      say "Applying cookbook locks to #{environment}..."
      lockfile = Berkshelf::Lockfile.from_file(file.path)
      unless lockfile.apply(environment)
        error "Failed to apply Berksfile.lock to #{environment}."
        exit(1)
      end

      run_chef(environment)
    ensure
      file.close(true) if file
    end

    private

      def ridley
        @ridley ||= Ridley.new(server_url: config.chef.chef_server_url, client_name: config.chef.node_name,
          client_key: config.chef.client_key, ssh: {
            user: @options[:ssh_user], password: @options[:ssh_password], keys: @options[:ssh_key],
            sudo: use_sudo?
        })
      end

      def config
        Berkshelf::Config.instance
      end

      def handle_results(result_set)
        failure,  success = result_set.partition { |result| result.error? }
        log_dir           = log_results(success, failure)
        [success, failure, log_dir]
      end

      def log_results(success, failure)
        out_dir     = File.join("berkflow_out", Time.now.strftime("%Y%m%d%H%M%S"))
        success_dir = File.join(out_dir, "success")
        failure_dir = File.join(out_dir, "failure")

        [success_dir, failure_dir].each { |dir| FileUtils.mkdir_p(dir) }
        success.each { |result| write_logs(result, success_dir) }
        failure.each { |result| write_logs(result, failure_dir) }
        out_dir
      end

      def sanitize_version(version)
        Solve::Version.new(version).to_s
      rescue Solve::Errors::InvalidVersionFormat
        error "Invalid version: #{version}. Provide a valid SemVer version string. (i.e. 1.2.3)."
        exit(1)
      end

      def find_cookbook!(application, version)
        unless cookbook = ridley.cookbook.find(application, version)
          error "Cookbook not found: #{application} (#{version})."
          exit(1)
        end
        cookbook
      end

      def find_environment!(environment)
        unless env = ridley.environment.find(environment)
          error "Environment not found: #{environment}"
          exit(1)
        end
        env
      end

      def find_nodes(environment)
        ridley.search(:node, "chef_environment:#{environment}")
      end

      def use_sudo?
        @options[:sudo].nil? ? true : @options[:sudo]
      end

      def write_logs(result, dir)
        write_stdout(result, dir)
        write_stderr(result, dir)
      end

      def write_stdout(result, dir)
        File.open(File.join(dir, "#{result.host}.stdout"), "w") { |file| file.write(result.stdout) }
      end

      def write_stderr(result, dir)
        File.open(File.join(dir, "#{result.host}.stderr"), "w") { |file| file.write(result.stderr) }
      end
  end
end
