# typed: true
# frozen_string_literal: true

require_relative "gh_cli"
require_relative "options"
require_relative "project"
require_relative "utils"

module ProjectPullMover
  class DataLoader
    extend T::Sig

    include Utils

    class Result
      extend T::Sig

      sig { params(pull_requests: T::Array[PullRequest]).returns(Result) }
      def self.success(pull_requests:)
        new(pull_requests: pull_requests)
      end

      sig { params(err: T.any(StandardError, String)).returns(Result) }
      def self.error(err)
        new(error: err.is_a?(String) ? err : err.message)
      end

      sig { params(error: T.nilable(String), pull_requests: T::Array[PullRequest]).void }
      def initialize(error: nil, pull_requests: [])
        @error = error
        @pull_requests = pull_requests
      end

      sig { returns T.nilable(String) }
      attr_reader :error

      sig { returns T::Array[PullRequest] }
      attr_reader :pull_requests

      sig { returns T::Boolean }
      def success?
        @error.nil?
      end
    end

    sig { params(gh_cli: GhCli, options: Options).void }
    def initialize(gh_cli:, options:)
      @gh_cli = gh_cli
      @options = options
      @project = T.let(Project.new(options), Project)
    end

    sig { returns Result }
    def load
      unless quiet_mode?
        output_loading_message("Looking up items in project #{@project.number} owned by @#{@project.owner}...")
      end

      project_items = begin
        @gh_cli.get_project_items
      rescue GhCli::NoJsonError => err
        return Result.error(err)
      end

      return Result.success(pull_requests: []) if project_items.size < 1

      unless quiet_mode?
        pull_units = project_items.size == 1 ? "pull request" : "pull requests"
        output_success_message("Found #{project_items.size} #{pull_units} in project")
      end

      author_pull_numbers_by_repo_nwo = begin
        @gh_cli.author_pull_numbers_by_repo_nwo
      rescue GhCli::NoJsonError => err
        return Result.error(err)
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
            output_info_message("All PRs in project were authored by @#{@options.author}")
          else
            after_units = total_project_items_after == 1 ? "pull request" : "pull requests"
            output_info_message("Filtered PRs in project down to #{total_project_items_after} #{after_units} authored " \
              "by @#{@options.author}")
          end
        end
      end

      project_pulls = project_items.map do |pull_info|
        ProjectPullMover::PullRequest.new(pull_info, options: @options, project: @project)
      end

      output_loading_message("Looking up more info about each pull request in project...") unless quiet_mode?
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
        output_info_message("Will make #{graphql_queries.size} API request(s) to get pull request data")
      end

      graphql_queries.each_with_index do |graphql_query, query_index|
        unless quiet_mode?
          output_loading_message("Making API request #{query_index + 1} of #{graphql_queries.size}...")
        end

        new_graphql_data = begin
          @gh_cli.make_graphql_api_query(graphql_query)
        rescue GhCli::GraphqlApiError => api_err
          return Result.error(api_err)
        end

        graphql_data.merge!(new_graphql_data)
      end

      if graphql_data["user"]
        @project.set_graphql_data(graphql_data["user"])
      elsif graphql_data["organization"]
        @project.set_graphql_data(graphql_data["organization"])
      end

      unless quiet_mode?
        output_info_message("'#{@options.status_field}' options enabled: #{@project.enabled_options.join(', ')}")
        output_info_message("Ignored '#{@options.status_field}' options: #{@project.ignored_option_names.join(', ')}")
      end

      project_pulls.each do |pull|
        extra_info = graphql_data[pull.graphql_field_alias]
        pull.set_graphql_data(extra_info) if extra_info
      end

      output_success_message("Loaded extra pull request info from the API") unless quiet_mode?

      Result.success(pull_requests: project_pulls)
    end

    private

    sig { returns(T::Boolean) }
    def quiet_mode?
      @options.quiet_mode?
    end
  end
end
