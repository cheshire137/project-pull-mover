#!/usr/bin/env ruby
# encoding: utf-8

require_relative "utils"

module ProjectPullMover
  class Project
    include Utils

    def initialize(options)
      @options = options
      @gql_data = {}
    end

    def set_graphql_data(value)
      @gql_data = value
    end

    def gh_path
      @gh_path ||= @options[:"gh-path"] || which("gh") || "gh"
    end

    def status_field
      @status_field ||= @options[:"status-field"]
    end

    def number
      @number ||= @options[:"project-number"]
    end

    def owner
      @owner ||= @options[:"project-owner"]
    end

    def owner_type
      @owner_type ||= @options[:"project-owner-type"]
    end

    def author
      @author ||= @options[:"author"]
    end

    def build_names_for_rerun
      @build_names_for_rerun ||= (@options[:"builds-to-rerun"] || []).map { |name| name.strip.downcase }
    end

    def quiet_mode?
      @options[:quiet]
    end

    def allow_marking_drafts?
      @options[:"mark-draft"]
    end

    def owner_graphql_field
      <<~GRAPHQL
        #{owner_type}(login: "#{owner}") {
          projectV2(number: #{number}) {
            title
            field(name: "#{status_field}") {
              ... on ProjectV2SingleSelectField {
                options { id name }
              }
            }
          }
        }
      GRAPHQL
    end

    def in_progress_option_name
      @in_progress_option_name ||= option_name_for(in_progress_option_id) || "In progress"
    end

    def in_progress_option_id
      @in_progress_option_id ||= @options[:"in-progress"]
    end

    def not_against_main_option_name
      @not_against_main_option_name ||= option_name_for(not_against_main_option_id) || "Not against main"
    end

    def not_against_main_option_id
      @not_against_main_option_id ||= @options[:"not-against-main"]
    end

    def needs_review_option_name
      @needs_review_option_name ||= option_name_for(needs_review_option_id) || "Needs review"
    end

    def needs_review_option_id
      @needs_review_option_id ||= @options[:"needs-review"]
    end

    def ready_to_deploy_option_name
      @ready_to_deploy_option_name ||= option_name_for(ready_to_deploy_option_id) || "Ready to deploy"
    end

    def ready_to_deploy_option_id
      @ready_to_deploy_option_id ||= @options[:"ready-to-deploy"]
    end

    def conflicting_option_name
      @conflicting_option_name ||= option_name_for(conflicting_option_id) || "Conflicting"
    end

    def conflicting_option_id
      @conflicting_option_id ||= @options[:"conflicting"]
    end

    def any_option_ids?
      in_progress_option_id || not_against_main_option_id || needs_review_option_id || ready_to_deploy_option_id ||
        conflicting_option_id
    end

    def enabled_options
      result = []
      result << in_progress_option_name if in_progress_option_id
      result << not_against_main_option_name if not_against_main_option_id
      result << needs_review_option_name if needs_review_option_id
      result << ready_to_deploy_option_name if ready_to_deploy_option_id
      result << conflicting_option_name if conflicting_option_id
      result
    end

    def ignored_option_names
      return @ignored_option_names if @ignored_option_names
      names = ignored_option_ids.map { |option_id| option_name_for(option_id) }.compact
      names = ["Ignored"] if names.size < 1
      @ignored_option_names = names
    end

    def ignored_option_ids
      @ignored_option_ids ||= @options[:"ignored"] || []
    end

    def title
      return @title if @title
      project_data = @gql_data["projectV2"]
      @title = if project_data
        project_data["title"]
      else
        "Unknown project"
      end
    end

    def failing_test_label_name
      return @failing_test_label_name if defined?(@failing_test_label_name)
      result = @options[:"failing-test-label"]
      if result
        result = result.strip
        if result.size < 1
          result = nil
        end
      end
      @failing_test_label_name = result
    end

    private

    def option_name_for(option_id)
      project_data = @gql_data["projectV2"]
      return unless project_data

      option_data = project_data["field"]["options"].detect { |option| option["id"] == option_id }
      return unless option_data

      option_data["name"]
    end
  end
end
