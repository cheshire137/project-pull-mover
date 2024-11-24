# typed: true
# frozen_string_literal: true

require "json"
require_relative "options"
require_relative "utils"

module ProjectPullMover
  class GhCli
    extend T::Sig

    include Utils

    class NoJsonError < StandardError; end
    class GraphqlApiError < StandardError; end

    sig { params(options: Options).void }
    def initialize(options)
      @options = options
    end

    def get_project_items
      project_items_cmd = "#{gh_path} project item-list #{@options.project_number} " \
        "--owner #{@options.project_owner} --format json --limit #{@options.proj_items_limit}"
      json = T.let(`#{project_items_cmd}`, T.nilable(String))
      if json.nil? || json == ""
        raise NoJsonError, "Error: no JSON results for project items; command: #{project_items_cmd}"
      end

      all_project_items = JSON.parse(json)["items"]
      unless quiet_mode?
        units = all_project_items.size == 1 ? "item" : "items"
        output_info_message("Found #{all_project_items.size} #{units} in project")
      end

      project_items = all_project_items.select { |item| item["content"]["type"] == "PullRequest" }
      if project_items.size < 1
        unless quiet_mode?
          output_success_message("No pull requests found in project #{@options.project_number} by " \
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

    sig { returns T.nilable(T::Hash[String, Integer]) }
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
      graphql_resp = JSON.parse(json_str)

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

      output_info_message("Looking up open pull requests by @#{@options.author} in project...") unless quiet_mode?

      pulls_by_author_in_project_cmd = "#{gh_path} search prs --author \"#{@options.author}\" --project " \
        "\"#{@options.project_owner}/#{@options.project_number}\" --json \"number,repository\" --limit #{@options.proj_items_limit} --state open"
      json = T.let(`#{pulls_by_author_in_project_cmd}`, T.nilable(String))
      if json.nil? || json == ""
        raise NoJsonError, "Error: no JSON results for pull requests by author in project; " \
          "command: #{pulls_by_author_in_project_cmd}"
      end

      JSON.parse(json)
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
