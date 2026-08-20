# typed: true
# frozen_string_literal: true

require_relative "gh_cli"
require_relative "logger"
require_relative "options"
require_relative "project"

module ProjectPullMover
  class ReopenedItemRestorer
    extend T::Sig

    sig { params(gh_cli: GhCli, options: Options, project: Project, logger: Logger).returns(Integer) }
    def self.run(gh_cli:, options:, project:, logger:)
      new(gh_cli: gh_cli, options: options, project: project, logger: logger).run
    end

    sig { params(gh_cli: GhCli, options: Options, project: Project, logger: Logger).void }
    def initialize(gh_cli:, options:, project:, logger:)
      @gh_cli = gh_cli
      @options = options
      @project = project
      @logger = logger
    end

    sig { returns(Integer) }
    def run
      in_progress_option_id = @options.in_progress_option_id
      return 0 unless in_progress_option_id

      open_content = @gh_cli.get_open_project_content
      return 0 if open_content.empty?

      restored_count = T.let(0, Integer)
      open_content.each_slice(@options.pull_fields_per_query) do |content_batch|
        graphql_data = @gh_cli.make_graphql_api_query(graphql_query(content_batch))

        content_batch.each_with_index do |content, index|
          item = project_item(graphql_data["content#{index}"])
          next unless item && item["isArchived"] && done_status?(item)

          item_name = content_name(content)
          project_item_id = item["id"]
          project = item["project"]
          field_value = item["fieldValueByName"]
          field = field_value && field_value["field"]
          unless project_item_id && project && project["id"] && field_value && field && field["id"]
            raise GhCli::UnexpectedJsonStructureError,
              "Error: archived project item is missing IDs or status data: #{item.inspect}"
          end

          @gh_cli.unarchive_project_item(project_item_id: project_item_id, item_name: item_name)
          @gh_cli.set_project_item_status(
            option_id: in_progress_option_id,
            project_item_id: project_item_id,
            project_global_id: project["id"],
            status_field_id: field["id"],
            old_option_name: field_value["name"],
            new_option_name: @project.in_progress_option_name,
            pull_name: item_name,
          )
          restored_count += 1
        end
      end

      unless quiet_mode?
        units = restored_count == 1 ? "item" : "items"
        if restored_count > 0
          @logger.info("Restored #{restored_count} reopened project #{units} to " \
            "'#{@project.in_progress_option_name}'")
        end
      end
      restored_count
    end

    private

    sig { params(content_batch: T::Array[T.untyped]).returns(String) }
    def graphql_query(content_batch)
      fields = content_batch.each_with_index.map do |content, index|
        repository = content["repository"]
        repo_nwo = repository && repository["nameWithOwner"]
        repo_owner, repo_name = repo_nwo&.split("/")
        number = content["number"]
        unless repo_owner && repo_name && number
          raise GhCli::UnexpectedJsonStructureError,
            "Error: open project content is missing repository or number: #{content.inspect}"
        end

        <<~GRAPHQL
          content#{index}: repository(owner: "#{repo_owner}", name: "#{repo_name}") {
            item: issueOrPullRequest(number: #{number}) {
              ... on Issue {
                #{project_items_field}
              }
              ... on PullRequest {
                #{project_items_field}
              }
            }
          }
        GRAPHQL
      end

      <<~GRAPHQL
        query {
          #{fields.join("\n")}
        }
      GRAPHQL
    end

    sig { returns(String) }
    def project_items_field
      <<~GRAPHQL
        projectItems(first: 100, includeArchived: true) {
          nodes {
            id
            isArchived
            project { id number }
            fieldValueByName(name: "#{@options.status_field}") {
              ... on ProjectV2ItemFieldSingleSelectValue {
                field { ... on ProjectV2SingleSelectField { id } }
                name
              }
            }
          }
        }
      GRAPHQL
    end

    sig { params(repository_data: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
    def project_item(repository_data)
      return unless repository_data

      content_data = repository_data["item"]
      project_items = content_data && content_data["projectItems"]
      nodes = project_items && project_items["nodes"]
      return unless nodes

      nodes.detect do |item|
        project = item["project"]
        project && project["number"] == @options.project_number
      end
    end

    sig { params(item: T::Hash[T.untyped, T.untyped]).returns(T::Boolean) }
    def done_status?(item)
      field_value = item["fieldValueByName"]
      status_name = field_value && field_value["name"]
      !!(status_name && status_name.match?(/\Adone\b/i))
    end

    sig { params(content: T::Hash[T.untyped, T.untyped]).returns(String) }
    def content_name(content)
      repository = content["repository"]
      repo_nwo = repository && repository["nameWithOwner"]
      type = content["isPullRequest"] ? "pull request" : "issue"
      repo_nwo ? "#{repo_nwo}##{content["number"]}" : "#{type} ##{content["number"]}"
    end

    sig { returns(T::Boolean) }
    def quiet_mode?
      @options.quiet_mode?
    end
  end
end
