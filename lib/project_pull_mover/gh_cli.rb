# typed: true
# frozen_string_literal: true

require "json"
require_relative "logger"
require_relative "options"
require_relative "utils"

module ProjectPullMover
  class GhCli
    extend T::Sig

    class NoJsonError < StandardError; end
    class GraphqlApiError < StandardError; end

    class JsonParseError < StandardError
      attr_reader :cause

      def initialize(message, cause = nil)
        super(message)
        @cause = cause
      end
    end

    sig { params(options: Options, logger: Logger).void }
    def initialize(options:, logger:)
      @options = options
      @logger = logger
    end

    sig do
      params(label_name: String, number: Integer, repo_nwo: String, pull_name: String).returns(T.nilable(String))
    end
    def apply_pull_request_label(label_name:, number:, repo_nwo:, pull_name:)
      @logger.loading("Applying label '#{label_name}' to #{pull_name}...") unless quiet_mode?
      `#{gh_path} pr edit #{number} --repo "#{repo_nwo}" --add-label "#{label_name}"`
    end

    sig do
      params(label_name: String, number: Integer, repo_nwo: String, pull_name: String).returns(T.nilable(String))
    end
    def remove_pull_request_label(label_name:, number:, repo_nwo:, pull_name:)
      @logger.loading("Removing label '#{label_name}' from #{pull_name}...") unless quiet_mode?
      `#{gh_path} pr edit #{number} --repo "#{repo_nwo}" --remove-label "#{label_name}"`
    end

    sig do
      params(run_id: T.untyped, repo_nwo: String, pull_name: String, build_name: T.nilable(String))
        .returns(T.nilable(String))
    end
    def rerun_failed_run(run_id:, repo_nwo:, pull_name:, build_name: nil)
      @logger.loading("Rerunning failed run #{build_name || run_id} for #{pull_name}...") unless quiet_mode?
      `#{gh_path} run rerun #{run_id} --failed --repo "#{repo_nwo}"`
    end

    sig { params(number: Integer, repo_nwo: String, pull_name: String).returns(T.nilable(String)) }
    def mark_pull_request_as_draft(number:, repo_nwo:, pull_name:)
      @logger.loading("Marking #{pull_name} as a draft...") unless quiet_mode?
      `#{gh_path} pr ready --undo #{number} --repo "#{repo_nwo}"`
    end

    sig do
      params(
        option_id: String,
        project_item_id: String,
        project_global_id: String,
        status_field_id: String,
        old_option_name: String,
        new_option_name: String,
        pull_name: String
      ).returns(T.nilable(String))
    end
    def set_project_item_status(option_id:, project_item_id:, project_global_id:, status_field_id:, old_option_name:, new_option_name:, pull_name:)
      @logger.loading("Moving #{pull_name} out of '#{old_option_name}' column to " \
        "'#{new_option_name}'...") unless quiet_mode?
      `#{gh_path} project item-edit --id #{project_item_id} --project-id #{project_global_id} --field-id #{status_field_id} --single-select-option-id #{option_id}`
    end

    sig { void }
    def check_auth_status
      auth_status_result = `#{gh_path} auth status`
      @logger.info(auth_status_result.dup.force_encoding("UTF-8"))
    end

    sig { returns T::Array[T.untyped] }
    def get_project_items
      project_items_cmd = "#{gh_path} project item-list #{@options.project_number} " \
        "--owner #{@options.project_owner} --format json --limit #{@options.proj_items_limit}"
      json = T.let(`#{project_items_cmd}`, T.nilable(String))
      if json.nil? || json == ""
        raise NoJsonError, "Error: no JSON results for project items; command: #{project_items_cmd}"
      end

      all_project_items = parse_json(json)["items"]
      unless quiet_mode?
        units = all_project_items.size == 1 ? "item" : "items"
        @logger.info("Found #{all_project_items.size} #{units} in project")
      end

      project_items = all_project_items.select { |item| item["content"]["type"] == "PullRequest" }
      if project_items.size < 1
        unless quiet_mode?
          @logger.success("No pull requests found in project #{@options.project_number} by " \
            "@#{@options.project_owner}")
        end
      end

      project_items
    end

    sig { returns T.nilable(T::Array[T.untyped]) }
    def pulls_by_author_in_project
      return @pulls_by_author_in_project if defined?(@pulls_by_author_in_project)
      @pulls_by_author_in_project = get_pulls_by_author_in_project
    end

    sig { returns T.nilable(T::Hash[String, T::Array[Integer]]) }
    def author_pull_numbers_by_repo_nwo
      pulls_by_author_in_project = self.pulls_by_author_in_project
      return unless pulls_by_author_in_project

      pulls_by_author_in_project.each_with_object({}) do |data, hash|
        repo_nwo = data["repository"]["nameWithOwner"]
        hash[repo_nwo] ||= []
        hash[repo_nwo] << data["number"]
      end
    end

    sig { params(graphql_query: String).returns(T.untyped) }
    def make_graphql_api_query(graphql_query)
      json_str = `#{gh_path} api graphql -f query='#{graphql_query}'`
      graphql_resp = parse_json(json_str)

      unless graphql_resp["data"]
        graphql_error_msg = if graphql_resp["errors"]
          graphql_resp["errors"].map { |err| err["message"] }.join("\n")
        else
          graphql_resp.inspect
        end
        raise GraphqlApiError, "Error: no data returned from the GraphQL API: #{graphql_error_msg}"
      end

      graphql_resp["data"]
    end

    private

    sig { returns T.nilable(T::Array[T.untyped]) }
    def get_pulls_by_author_in_project
      return unless @options.author

      @logger.info("Looking up open pull requests by @#{@options.author} in project...") unless quiet_mode?

      pulls_by_author_in_project_cmd = "#{gh_path} search prs --author \"#{@options.author}\" --project " \
        "\"#{@options.project_owner}/#{@options.project_number}\" --json \"number,repository\" --limit #{@options.proj_items_limit} --state open"
      json = T.let(`#{pulls_by_author_in_project_cmd}`, T.nilable(String))
      if json.nil? || json == ""
        raise NoJsonError, "Error: no JSON results for pull requests by author in project; " \
          "command: #{pulls_by_author_in_project_cmd}"
      end

      parse_json(json)
    end

    sig { params(input: String).returns(T.untyped) }
    def parse_json(input)
      JSON.parse(input.encode("UTF-8"))
    rescue Encoding::InvalidByteSequenceError => err
      raise JsonParseError.new("Could not parse JSON due to invalid byte sequence: #{err.message}", err)
    end

    sig { returns(T::Boolean) }
    def quiet_mode?
      @options.quiet_mode?
    end

    sig { returns(String) }
    def gh_path
      @options.gh_path
    end
  end
end
