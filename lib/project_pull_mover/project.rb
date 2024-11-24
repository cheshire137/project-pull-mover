# typed: true
# frozen_string_literal: true
# encoding: utf-8

require_relative "options"

module ProjectPullMover
  class Project
    extend T::Sig

    sig { params(options: Options).void }
    def initialize(options)
      @options = options
      @gql_data = {}
    end

    def set_graphql_data(value)
      @gql_data = value
    end

    def number
      @number ||= @options.project_number
    end

    def owner
      @owner ||= @options.project_owner
    end

    def owner_type
      @owner_type ||= @options.project_owner_type
    end

    def owner_graphql_field
      <<~GRAPHQL
        #{owner_type}(login: "#{owner}") {
          projectV2(number: #{number}) {
            title
            field(name: "#{@options.status_field}") {
              ... on ProjectV2SingleSelectField {
                options { id name }
              }
            }
          }
        }
      GRAPHQL
    end

    def in_progress_option_name
      @in_progress_option_name ||= option_name_for(@options.in_progress_option_id) || "In progress"
    end

    def not_against_main_option_name
      @not_against_main_option_name ||= option_name_for(@options.not_against_main_option_id) || "Not against main"
    end

    def needs_review_option_name
      @needs_review_option_name ||= option_name_for(@options.needs_review_option_id) || "Needs review"
    end

    def ready_to_deploy_option_name
      @ready_to_deploy_option_name ||= option_name_for(@options.ready_to_deploy_option_id) || "Ready to deploy"
    end

    def conflicting_option_name
      @conflicting_option_name ||= option_name_for(@options.conflicting_option_id) || "Conflicting"
    end

    def enabled_options
      result = []
      result << in_progress_option_name if @options.in_progress_option_id
      result << not_against_main_option_name if @options.not_against_main_option_id
      result << needs_review_option_name if @options.needs_review_option_id
      result << ready_to_deploy_option_name if @options.ready_to_deploy_option_id
      result << conflicting_option_name if @options.conflicting_option_id
      result
    end

    def ignored_option_names
      return @ignored_option_names if @ignored_option_names
      names = @options.ignored_option_ids.map { |option_id| option_name_for(option_id) }.compact
      names = ["Ignored"] if names.size < 1
      @ignored_option_names = names
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
      result = @options.failing_test_label
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
