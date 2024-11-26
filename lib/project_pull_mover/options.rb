# typed: true
# frozen_string_literal: true

require "optparse"
require_relative "logger"
require_relative "utils"

module ProjectPullMover
  class Options
    extend T::Sig

    class InvalidOptionsError < StandardError; end

    sig do
      params(
        file: String,
        logger: Logger,
        proj_items_limit: Integer,
        pull_fields_per_query: Integer,
        argv: Array
      ).returns(Options)
    end
    def self.parse(file:, logger:, proj_items_limit: 100, pull_fields_per_query: 5, argv: ARGV)
      options = new(file: file, logger: logger, proj_items_limit: proj_items_limit,
        pull_fields_per_query: pull_fields_per_query, argv: argv)
      raise InvalidOptionsError, options.error_message unless options.parse
      options
    end

    sig { returns Integer }
    attr_reader :proj_items_limit

    sig { returns Integer }
    attr_reader :pull_fields_per_query

    sig { returns T.nilable(String) }
    attr_reader :error_message

    sig do
      params(
        file: String,
        logger: Logger,
        proj_items_limit: Integer,
        pull_fields_per_query: Integer,
        argv: Array
      ).void
    end
    def initialize(file:, logger:, proj_items_limit: 100, pull_fields_per_query: 5, argv: ARGV)
      @options = T.let({}, T::Hash[Symbol, T.untyped])
      @proj_items_limit = proj_items_limit
      @pull_fields_per_query = pull_fields_per_query
      @logger = logger
      @argv = argv
      @error_message = T.let(nil, T.nilable(String))
      @option_parser = T.let(OptionParser.new do |opts|
        opts.banner = "Usage: #{file} [options]"
        opts.on("-p NUM", "--project-number", Integer,
          "Project number (required), e.g., 123 for https://github.com/orgs/someorg/projects/123")
        opts.on("-o OWNER", "--project-owner", String,
          "Project owner login (required), e.g., someorg for https://github.com/orgs/someorg/projects/123")
        opts.on("-t TYPE", "--project-owner-type", String,
          "Project owner type (required), either 'user' or 'organization'")
        opts.on("-s STATUS", "--status-field", String,
          "Status field name (required), name of a single-select field in the project")
        opts.on("-i ID", "--in-progress", String, "Option ID of 'In progress' column for status field")
        opts.on("-a ID", "--not-against-main", String, "Option ID of 'Not against main' column for status field")
        opts.on("-n ID", "--needs-review", String, "Option ID of 'Needs review' column for status field")
        opts.on("-r ID", "--ready-to-deploy", String, "Option ID of 'Ready to deploy' column for status field")
        opts.on("-c ID", "--conflicting", String, "Option ID of 'Conflicting' column for status field")
        opts.on("-g IDS", "--ignored", Array,
          "Optional comma-separated list of option IDs of columns like 'Blocked' or 'On hold' for status field")
        opts.on("-q", "--quiet", "Quiet mode, suppressing all output except errors")
        opts.on("-h PATH", "--gh-path", String, "Path to gh executable")
        opts.on("-f LABEL", "--failing-test-label", String, "Name of the label to apply to a pull request that has " \
          "failing required builds")
        opts.on("-u AUTHOR", "--author", String, "Specify a username so that only PRs in the project authored by that " \
          "user are changed")
        opts.on("-m", "--mark-draft", "Also mark pull requests as a draft when setting them to In Progress, " \
          "Not Against Main, or Conflicting status.")
        opts.on("-b BUILDS", "--builds-to-rerun", Array, "Case-insensitive comma-separated list of build names or " \
          "partial build names that should be re-run when they are failing and the pull request is moved them back " \
          "to In Progress status")
        opts.on("-v", "--version", "Print version and exit")
      end, OptionParser)
    end

    sig { returns(T::Boolean) }
    def parse
      @option_parser.parse!(@argv, into: @options)
      return true if print_version?
      valid?
    end

    sig { returns(T::Boolean) }
    def print_version?
      !!@options[:version]
    end

    sig { returns String }
    def gh_path
      @options[:"gh-path"] || Utils.which("gh") || "gh"
    end

    sig { returns T.nilable(String) }
    def status_field
      @options[:"status-field"]
    end

    sig { returns T.nilable(Integer) }
    def project_number
      @options[:"project-number"]
    end

    sig { returns T.nilable(String) }
    def project_owner
      @options[:"project-owner"]
    end

    sig { returns T.nilable(String) }
    def project_owner_type
      @options[:"project-owner-type"]
    end

    sig { returns T.nilable(String) }
    def author
      @options[:"author"]
    end

    sig { returns T::Array[String] }
    def build_names_for_rerun
      (@options[:"builds-to-rerun"] || []).map { |name| name.strip.downcase }
    end

    sig { returns T::Boolean }
    def quiet_mode?
      !!@options[:quiet]
    end

    sig { returns T::Boolean }
    def allow_marking_drafts?
      !!@options[:"mark-draft"]
    end

    sig { returns T.nilable(String)}
    def in_progress_option_id
      @options[:"in-progress"]
    end

    sig { returns T.nilable(String)}
    def not_against_main_option_id
      @options[:"not-against-main"]
    end

    sig { returns T.nilable(String)}
    def needs_review_option_id
      @options[:"needs-review"]
    end

    sig { returns T.nilable(String)}
    def ready_to_deploy_option_id
      @options[:"ready-to-deploy"]
    end

    sig { returns T.nilable(String)}
    def conflicting_option_id
      @options[:"conflicting"]
    end

    sig { returns T::Array[String] }
    def ignored_option_ids
      @options[:"ignored"] || []
    end

    sig { returns T.nilable(String) }
    def failing_test_label
      return @failing_test_label if defined?(@failing_test_label)
      value = @options[:"failing-test-label"]
      if value
        value = value.strip
        if value.size < 1
          value = nil
        end
      end
      @failing_test_label = value
    end

    sig { returns String }
    def to_s
      @option_parser.to_s
    end

    sig { returns T::Boolean }
    def any_option_ids?
      result = in_progress_option_id || not_against_main_option_id || needs_review_option_id ||
        ready_to_deploy_option_id || conflicting_option_id
      !!result
    end

    private

    sig { returns T::Boolean }
    def valid?
      unless project_number && project_owner && status_field
        @error_message = "Error: missing required options"
        @logger.error(@error_message)
        @logger.info(to_s)
        return false
      end

      unless %w(user organization).include?(project_owner_type)
        @error_message = "Error: invalid project owner type"
        @logger.error(@error_message)
        @logger.info(to_s)
        return false
      end

      unless any_option_ids?
        @error_message = "Error: you must specify at least one option ID for the status field"
        @logger.error(@error_message)
        @logger.info(to_s)
        return false
      end

      true
    end
  end
end
