# typed: true
# frozen_string_literal: true

require_relative "options"
require_relative "utils"

module ProjectPullMover
  class GhCli
    extend T::Sig

    include Utils

    class NoJsonError < StandardError; end

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

    private

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
