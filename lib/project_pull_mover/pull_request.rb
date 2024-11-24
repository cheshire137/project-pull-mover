# typed: true
# frozen_string_literal: true
# encoding: utf-8

require_relative "gh_cli"
require_relative "utils"

module ProjectPullMover
  class PullRequest
    extend T::Sig

    include Utils

    sig { params(data: T::Hash[T.untyped, T.untyped], options: Options, project: Project, gh_cli: GhCli).void }
    def initialize(data, options:, project:, gh_cli:)
      @data = data
      @options = options
      @gql_data = {}
      @repo = nil
      @project = project
      @gh_cli = gh_cli
    end

    def set_graphql_data(repo_and_pull_data)
      @repo ||= Repository.new(repo_and_pull_data, failing_test_label_name: @project.failing_test_label_name)
      @gql_data = repo_and_pull_data["pullRequest"] || {}
    end

    def number
      @number ||= @data["content"]["number"]
    end

    def has_failing_test_label?
      @project.failing_test_label_name && labels.include?(@project.failing_test_label_name)
    end

    def labels
      @labels ||= @data["labels"] || []
    end

    def repo_name_with_owner
      @repo_name_with_owner ||= @data["content"]["repository"]
    end

    def repo_owner
      return @repo_owner if @repo_owner
      @repo_owner, @repo_name = repo_name_with_owner.split("/")
      @repo_owner
    end

    def repo_name
      return @repo_name if @repo_name
      @repo_owner, @repo_name = repo_name_with_owner.split("/")
      @repo_name
    end

    def to_s
      "#{repo_name_with_owner}##{number}"
    end

    def graphql_field_alias
      @graphql_field_alias ||= "pull#{replace_hyphens(repo_owner)}#{replace_hyphens(repo_name)}#{number}"
    end

    def graphql_field
      <<~GRAPHQL
        #{graphql_field_alias}: repository(owner: "#{repo_owner}", name: "#{repo_name}") {
          id
          defaultBranchRef { name }
          pullRequest(number: #{number}) {
            isDraft
            isInMergeQueue
            reviewDecision
            mergeable
            baseRefName
            commits(last: 1) {
              nodes {
                commit {
                  checkSuites(first: 100) {
                    nodes {
                      checkRuns(
                        first: 100
                        filterBy: {checkType: LATEST, conclusions: [ACTION_REQUIRED, TIMED_OUT, CANCELLED, FAILURE, STARTUP_FAILURE]}
                      ) {
                        nodes {
                          name
                          isRequired(pullRequestNumber: #{number})
                        }
                      }
                    }
                  }
                  status {
                    contexts {
                      context
                      state
                      isRequired(pullRequestNumber: #{number})
                    }
                  }
                }
              }
            }
            projectItems(first: 100) {
              nodes {
                id
                project { id number }
                fieldValueByName(name: "#{@options.status_field}") {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    field { ... on ProjectV2SingleSelectField { id } }
                    optionId
                    name
                  }
                }
              }
            }
          }
        }
      GRAPHQL
    end

    def failing_required_builds?
      failing_required_check_suites? || failing_required_statuses?
    end

    def failing_required_check_suites?
      return false unless last_commit

      last_commit["checkSuites"]["nodes"].any? do |check_suite|
        check_suite["checkRuns"]["nodes"].any? do |check_run|
          check_run["isRequired"]
        end
      end
    end

    def failing_required_statuses?
      return false unless last_commit

      status = last_commit["status"]
      return false unless status

      status["contexts"].any? do |context|
        context["isRequired"] && context["state"] == "FAILURE"
      end
    end

    def project_item
      @project_item ||= @gql_data["projectItems"]["nodes"].detect do |item|
        item["project"]["number"] == @project.number
      end
    end

    def project_item_id
      @project_item_id ||= project_item["id"]
    end

    def project_global_id
      return unless project_item
      @project_global_id ||= project_item["project"]["id"]
    end

    def current_status_option_id
      return unless project_item
      @current_status_option_id ||= project_item["fieldValueByName"]["optionId"]
    end

    def current_status_option_name
      return unless project_item
      @current_status_option_name ||= project_item["fieldValueByName"]["name"]
    end

    def status_field_id
      return unless project_item
      @status_field_id ||= project_item["fieldValueByName"]["field"]["id"]
    end

    def enqueued?
      @gql_data["isInMergeQueue"]
    end

    def draft?
      @gql_data["isDraft"]
    end

    def mergeable_state
      @mergeable_state ||= @gql_data["mergeable"]
    end

    def unknown_merge_state?
      mergeable_state == "UNKNOWN"
    end

    def conflicting?
      mergeable_state == "CONFLICTING"
    end

    def review_decision
      @gql_data["reviewDecision"]
    end

    def approved?
      review_decision == "APPROVED"
    end

    def base_branch
      @gql_data["baseRefName"]
    end

    def against_default_branch?
      @repo && base_branch == @repo.default_branch
    end

    def daisy_chained?
      @repo && !against_default_branch?
    end

    def has_in_progress_status?
      current_status_option_id == @options.in_progress_option_id
    end

    def has_not_against_main_status?
      current_status_option_id == @options.not_against_main_option_id
    end

    def has_needs_review_status?
      current_status_option_id == @options.needs_review_option_id
    end

    def has_ready_to_deploy_status?
      current_status_option_id == @options.ready_to_deploy_option_id
    end

    def has_conflicting_status?
      current_status_option_id == @options.conflicting_option_id
    end

    def has_ignored_status?
      @options.ignored_option_ids.include?(current_status_option_id)
    end

    def set_in_progress_status
      option_id = @options.in_progress_option_id
      return unless option_id

      @gh_cli.set_project_item_status(
        option_id: option_id,
        project_item_id: project_item_id,
        project_global_id: project_global_id,
        status_field_id: status_field_id,
        old_option_name: current_status_option_name,
        new_option_name: @project.in_progress_option_name,
      )
    end

    def set_needs_review_status
      option_id = @options.needs_review_option_id
      return unless option_id

      @gh_cli.set_project_item_status(
        option_id: option_id,
        project_item_id: project_item_id,
        project_global_id: project_global_id,
        status_field_id: status_field_id,
        old_option_name: current_status_option_name,
        new_option_name: @project.needs_review_option_name,
      )
    end

    def set_not_against_main_status
      option_id = @options.not_against_main_option_id
      return unless option_id

      @gh_cli.set_project_item_status(
        option_id: option_id,
        project_item_id: project_item_id,
        project_global_id: project_global_id,
        status_field_id: status_field_id,
        old_option_name: current_status_option_name,
        new_option_name: @project.not_against_main_option_name,
      )
    end

    def set_ready_to_deploy_status
      option_id = @options.ready_to_deploy_option_id
      return unless option_id

      @gh_cli.set_project_item_status(
        option_id: option_id,
        project_item_id: project_item_id,
        project_global_id: project_global_id,
        status_field_id: status_field_id,
        old_option_name: current_status_option_name,
        new_option_name: @project.ready_to_deploy_option_name,
      )
    end

    def set_conflicting_status
      option_id = @options.conflicting_option_id
      return unless option_id

      @gh_cli.set_project_item_status(
        option_id: option_id,
        project_item_id: project_item_id,
        project_global_id: project_global_id,
        status_field_id: status_field_id,
        old_option_name: current_status_option_name,
        new_option_name: @project.conflicting_option_name,
      )
    end

    def apply_label(label_name:)
      @gh_cli.apply_pull_request_label(label_name: label_name, number: number, repo_nwo: repo_name_with_owner,
        pull_name: to_s)
    end

    def remove_label(label_name:)
      @gh_cli.remove_pull_request_label(label_name: label_name, number: number, repo_nwo: repo_name_with_owner,
        pull_name: to_s)
    end

    def rerun_failed_run(run_id:)
      @gh_cli.rerun_failed_run(run_id: run_id, build_name: build_name_for_run_id(run_id),
        repo_nwo: repo_name_with_owner)
    end

    def rerun_failing_required_builds
      return if build_names_for_rerun.size < 1

      build_names_for_rerun.each do |build_name|
        run_id = run_id_for_build_name(build_name)
        if run_id
          rerun_failed_run(run_id: run_id)
        end
      end
    end

    def mark_as_draft
      @gh_cli.mark_pull_request_as_draft(number: number, repo_nwo: repo_name_with_owner)
    end

    def can_mark_as_draft?
      !draft? && !enqueued? && @options.allow_marking_drafts?
    end

    def should_have_in_progress_status?
      return false if has_ignored_status?
      return false unless @options.in_progress_option_id # can't
      return false if enqueued? # don't say it's in progress if we're already in the merge queue

      # If we have a 'Conflicting' column...
      if @options.conflicting_option_id
        return false if conflicting? # don't put PR with merge conflicts into 'In progress'
        return false if unknown_merge_state? # don't assume it's not conflicting if we can't tell
      end

      # If not based on 'main', should be in 'Not against main' if we have such a column
      return false if daisy_chained? && @options.not_against_main_option_id

      if has_needs_review_status? || has_ready_to_deploy_status?
        failing_required_builds? || draft?
      else # Conflicting, Not against main, In progress
        !approved? || draft?
      end
    end

    def should_have_needs_review_status?
      return false if has_ignored_status?
      return false unless @options.needs_review_option_id # can't
      return false if conflicting? # don't ask for review when there are conflicts to resolve
      return false if draft? # don't ask for review if it's still a draft
      return false if daisy_chained? # don't ask for review when base branch will change

      # Don't ask for review if we're already in the merge queue and have a 'Ready to deploy' column:
      return false if enqueued? && @options.ready_to_deploy_option_id

      already_approved_check = if @options.ready_to_deploy_option_id
        # Only care about whether the PR has received an approval if there's another column it could move to
        # after 'Needs review'.
        !approved?
      else
        true
      end

      already_approved_check && (has_in_progress_status? || has_conflicting_status? || has_ready_to_deploy_status? ||
        has_not_against_main_status?)
    end

    def should_have_not_against_main_status?
      return false if has_ignored_status?
      return false unless @options.not_against_main_option_id # can't
      daisy_chained?
    end

    def should_have_ready_to_deploy_status?
      return false if has_ignored_status?
      return false unless @options.ready_to_deploy_option_id # can't
      !draft? && enqueued?
    end

    def should_have_conflicting_status?
      return false if has_ignored_status?
      return false unless @options.conflicting_option_id # can't
      against_default_branch? && conflicting? && !enqueued?
    end

    def should_apply_failing_test_label?
      failing_required_builds? && failing_test_label_name && !has_failing_test_label?
    end

    def apply_label_if_necessary
      if should_apply_failing_test_label?
        apply_label(label_name: failing_test_label_name)
        return failing_test_label_name
      end

      nil
    end

    def should_remove_failing_test_label?
      !failing_required_builds? && failing_test_label_name && has_failing_test_label?
    end

    def remove_label_if_necessary
      if should_remove_failing_test_label?
        remove_label(label_name: failing_test_label_name)
        return failing_test_label_name
      end

      nil
    end

    def change_status_if_necessary
      return nil if has_ignored_status?

      if should_have_conflicting_status?
        no_op = has_conflicting_status?
        set_conflicting_status unless no_op
        mark_as_draft if can_mark_as_draft?
        return no_op ? nil : @project.conflicting_option_name
      end

      if should_have_not_against_main_status?
        no_op = has_not_against_main_status?
        set_not_against_main_status unless no_op
        mark_as_draft if can_mark_as_draft?
        return no_op ? nil : @project.not_against_main_option_name
      end

      if should_have_ready_to_deploy_status?
        no_op = has_ready_to_deploy_status?
        set_ready_to_deploy_status unless no_op
        return no_op ? nil : @project.ready_to_deploy_option_name
      end

      if should_have_needs_review_status?
        no_op = has_needs_review_status?
        set_needs_review_status unless no_op
        return no_op ? nil : @project.needs_review_option_name
      end

      if should_have_in_progress_status?
        no_op = has_in_progress_status?
        unless no_op
          set_in_progress_status
          rerun_failing_required_builds
        end
        mark_as_draft if can_mark_as_draft?
        return no_op ? nil : @project.in_progress_option_name
      end

      nil
    end

    private

    def failed_required_run_ids_by_name
      return @failed_required_run_ids_by_name if @failed_required_run_ids_by_name
      result = {}
      regex = %r{/actions/runs/(\d+)/job/}
      failed_required_checks.each do |check|
        url = check["link"]
        matches = regex.match(url)
        if matches
          run_id = matches[1]
          name = check["name"].strip.downcase
          result[name] = run_id
        end
      end
      @failed_required_run_ids_by_name = result
    end

    def build_name_for_run_id(target_run_id)
      failed_required_run_ids_by_name.each do |name, run_id|
        return name if run_id == target_run_id
      end
      nil
    end

    def run_id_for_build_name(build_name)
      failed_run_ids_by_name = failed_required_run_ids_by_name

      if failed_run_ids_by_name.key?(build_name) # exact match
        return failed_run_ids_by_name[build_name]
      end

      failed_run_ids_by_name.each do |name, run_id|
        if name.include?(build_name) # partial match
          return run_id
        end
      end

      nil
    end

    def failed_required_checks
      return @failed_required_checks if @failed_required_checks
      required_checks = load_required_checks
      @failed_required_checks = required_checks.select { |check| "FAILURE" == check["state"] }
    end

    def load_required_checks
      json_str = T.let(
        `#{gh_path} pr checks #{number} --repo "#{repo_name_with_owner}" --required --json "link,state,name"`,
        T.nilable(String)
      )
      json_str.nil? || json_str.size < 1 ? [] : JSON.parse(json_str)
    end

    def failing_test_label_name
      @project.failing_test_label_name
    end

    def build_names_for_rerun
      @options.build_names_for_rerun
    end

    def last_commit
      return @last_commit if defined?(@last_commit)
      node = @gql_data["commits"]["nodes"][0]
      @last_commit = if node
        node["commit"]
      end
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
