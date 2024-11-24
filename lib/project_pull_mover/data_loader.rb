# typed: true
# frozen_string_literal: true

require_relative "gh_cli"
require_relative "logger"
require_relative "options"
require_relative "project"

module ProjectPullMover
  class DataLoader
    extend T::Sig

    sig { params(gh_cli: GhCli, options: Options, logger: Logger).returns(T.any(Result, ErrorDetails)) }
    def self.call(gh_cli:, options:, logger:)
      new(gh_cli: gh_cli, options: options, logger: logger).load
    end

    class ErrorDetails
      extend T::Sig

      sig { params(err: T.any(StandardError, String)).void }
      def initialize(err)
        @error_message = err.is_a?(String) ? err : err.message
      end

      sig { returns String }
      attr_reader :error_message

      sig { returns T::Boolean }
      def success?
        false
      end
    end

    class Result
      extend T::Sig

      sig { params(project: Project, pull_requests: T::Array[PullRequest]).void }
      def initialize(project:, pull_requests: [])
        @project = project
        @pull_requests = pull_requests
      end

      sig { returns T::Array[PullRequest] }
      attr_reader :pull_requests

      sig { returns Project }
      attr_reader :project

      sig { returns T::Boolean }
      def success?
        true
      end
    end

    sig { params(gh_cli: GhCli, options: Options, logger: Logger).void }
    def initialize(gh_cli:, options:, logger:)
      @gh_cli = gh_cli
      @options = options
      @logger = logger
      @project = T.let(Project.new(options), Project)
    end

    sig { returns T.any(Result, ErrorDetails) }
    def load
      unless quiet_mode?
        @logger.loading("Looking up items in project #{@project.number} owned by @#{@project.owner}...")
      end

      project_items = begin
        @gh_cli.get_project_items
      rescue GhCli::NoJsonError => err
        return ErrorDetails.new(err)
      end

      return Result.new(project: @project, pull_requests: []) if project_items.size < 1

      unless quiet_mode?
        pull_units = project_items.size == 1 ? "pull request" : "pull requests"
        @logger.success("Found #{project_items.size} #{pull_units} in project")
      end

      author_pull_numbers_by_repo_nwo = begin
        @gh_cli.author_pull_numbers_by_repo_nwo
      rescue GhCli::NoJsonError => err
        return ErrorDetails.new(err)
      end

      if author_pull_numbers_by_repo_nwo
        total_project_items_before = project_items.size
        project_items = project_items.select do |item|
          item_repo_nwo = item["content"]["repository"]
          item_pr_number = item["content"]["number"]
          author_pull_numbers_by_repo_nwo.key?(item_repo_nwo) &&
            (author_pull_numbers_by_repo_nwo[item_repo_nwo] || []).include?(item_pr_number)
        end
        total_project_items_after = project_items.size

        unless quiet_mode?
          if total_project_items_before == total_project_items_after
            @logger.info("All PRs in project were authored by @#{@options.author}")
          else
            after_units = total_project_items_after == 1 ? "pull request" : "pull requests"
            @logger.info("Filtered PRs in project down to #{total_project_items_after} #{after_units} authored " \
              "by @#{@options.author}")
          end
        end
      end

      project_pulls = project_items.map do |pull_info|
        ProjectPullMover::PullRequest.new(pull_info, options: @options, project: @project, gh_cli: @gh_cli)
      end

      @logger.loading("Looking up more info about each pull request in project...") unless quiet_mode?
      graphql_queries = []
      graphql_data = {}
      pull_fields = project_pulls.map(&:graphql_field)

      graphql_queries << <<~GRAPHQL
        query {
          #{@project.owner_graphql_field}
          #{pull_fields.take(@options.pull_fields_per_query).join("\n")}
        }
      GRAPHQL

      remaining_pull_fields = pull_fields.drop(@options.pull_fields_per_query)
      remaining_pull_fields.each_slice(@options.pull_fields_per_query) do |pull_fields_in_batch|
        graphql_queries << <<~GRAPHQL
          query {
            #{pull_fields_in_batch.join("\n")}
          }
        GRAPHQL
      end

      unless quiet_mode?
        @logger.info("Will make #{graphql_queries.size} API request(s) to get pull request data")
      end

      graphql_queries.each_with_index do |graphql_query, query_index|
        unless quiet_mode?
          @logger.loading("Making API request #{query_index + 1} of #{graphql_queries.size}...")
        end

        new_graphql_data = begin
          @gh_cli.make_graphql_api_query(graphql_query)
        rescue GhCli::GraphqlApiError => api_err
          return ErrorDetails.new(api_err)
        end

        graphql_data.merge!(new_graphql_data)
      end

      if graphql_data["user"]
        @project.set_graphql_data(graphql_data["user"])
      elsif graphql_data["organization"]
        @project.set_graphql_data(graphql_data["organization"])
      end

      unless quiet_mode?
        @logger.info("'#{@options.status_field}' options enabled: #{@project.enabled_options.join(', ')}")
        @logger.info("Ignored '#{@options.status_field}' options: #{@project.ignored_option_names.join(', ')}")
      end

      project_pulls.each do |pull|
        extra_info = graphql_data[pull.graphql_field_alias]
        pull.set_graphql_data(extra_info) if extra_info
      end

      @logger.success("Loaded extra pull request info from the API") unless quiet_mode?

      Result.new(project: @project, pull_requests: project_pulls)
    end

    private

    sig { returns(T::Boolean) }
    def quiet_mode?
      @options.quiet_mode?
    end
  end
end
