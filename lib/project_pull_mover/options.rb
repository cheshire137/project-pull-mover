# typed: true
# frozen_string_literal: true

require "optparse"
require_relative "utils"

module ProjectPullMover
  class Options
    extend T::Sig

    include Utils

    sig { returns Integer }
    attr_reader :proj_items_limit

    sig { params(file: String, proj_items_limit: Integer).void }
    def initialize(file:, proj_items_limit:)
      @options = {}
      @proj_items_limit = proj_items_limit
      @option_parser = OptionParser.new do |opts|
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
      end
    end

    sig { void }
    def parse
      @option_parser.parse!(into: @options)
    end

    sig { returns String }
    def gh_path
      @options[:"gh-path"] || which("gh") || "gh"
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
      @options[:"failing-test-label"]
    end

    def to_s
      @option_parser.to_s
    end

    sig { returns T::Boolean }
    def any_option_ids?
      result = in_progress_option_id || not_against_main_option_id || needs_review_option_id ||
        ready_to_deploy_option_id || conflicting_option_id
      !!result
    end

    sig { returns T::Boolean }
    def valid?
      unless project_number && project_owner && status_field
        output_error_message("Error: missing required options")
        puts to_s
        return false
      end

      unless %w(user organization).include?(project_owner_type)
        output_error_message("Error: invalid project owner type")
        puts to_s
        return false
      end

      unless any_option_ids?
        output_error_message("Error: you must specify at least one option ID for the status field")
        puts to_s
        return false
      end

      true
    end
  end
end