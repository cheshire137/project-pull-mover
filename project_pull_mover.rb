#!/usr/bin/env ruby
# encoding: utf-8

require "digest"
require "json"
require "optparse"
require "set"

options = {}
option_parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{__FILE__} [options]"
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
option_parser.parse!(into: options)

def output_error_message(content)
  STDERR.puts "❌ #{content}".force_encoding("UTF-8")
end

def which(cmd)
  exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
  ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
    exts.each do |ext|
      exe = File.join(path, "#{cmd}#{ext}")
      return exe if File.executable?(exe) && !File.directory?(exe)
    end
  end
  nil
end

limit = 500

class Project
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

project = Project.new(options)
gh_path = project.gh_path
failing_test_label_name = project.failing_test_label_name

unless gh_path
  output_error_message("Error: gh executable not found")
  puts option_parser
  exit 1
end

unless project.number && project.owner && project.status_field
  output_error_message("Error: missing required options")
  puts option_parser
  exit 1
end

unless %w(user organization).include?(project.owner_type)
  output_error_message("Error: invalid project owner type")
  puts option_parser
  exit 1
end

unless project.any_option_ids?
  output_error_message("Error: you must specify at least one option ID for the status field")
  puts option_parser
  exit 1
end

quiet_mode = project.quiet_mode?

def output_loading_message(content)
  puts "⏳ #{content}".force_encoding("UTF-8")
end

def output_success_message(content)
  puts "✅ #{content}".force_encoding("UTF-8")
end

def output_info_message(content)
  puts "ℹ️ #{content}".force_encoding("UTF-8")
end

def send_desktop_notification(content:, title:)
  has_osascript = which("osascript")
  if has_osascript
    quote_regex = /["']/
    content = content.gsub(quote_regex, "")
    title = title.gsub(quote_regex, "")
    `osascript -e 'display notification "#{content}" with title "#{title}"'`
  end
end

unless quiet_mode
  auth_status_result = `#{gh_path} auth status`
  output_info_message(auth_status_result.force_encoding("UTF-8"))
end

unless quiet_mode
  output_loading_message("Looking up items in project #{project.number} owned by @#{project.owner}...")
end

project_items_cmd = "#{gh_path} project item-list #{project.number} --owner #{project.owner} --format json " \
  "--limit #{limit}"
json = `#{project_items_cmd}`
if json.nil? || json == ""
  output_error_message("Error: no JSON results for project items; command: #{project_items_cmd}")
  exit 1
end

all_project_items = JSON.parse(json)["items"]
unless quiet_mode
  units = all_project_items.size == 1 ? "item" : "items"
  output_info_message("Found #{all_project_items.size} #{units} in project")
end

project_items = all_project_items.select { |item| item["content"]["type"] == "PullRequest" }
if project_items.size < 1
  output_success_message("No pull requests found in project #{project.number} by @#{project.owner}") unless quiet_mode
  exit 0
end

unless quiet_mode
  pull_units = project_items.size == 1 ? "pull request" : "pull requests"
  output_success_message("Found #{project_items.size} #{pull_units} in project")
end

if project.author
  output_info_message("Looking up open pull requests by @#{project.author} in project...") unless quiet_mode

  pulls_by_author_in_project_cmd = "#{gh_path} search prs --author \"#{project.author}\" --project " \
    "\"#{project.owner}/#{project.number}\" --json \"number,repository\" --limit #{limit} --state open"
  json = `#{pulls_by_author_in_project_cmd}`
  if json.nil? || json == ""
    output_error_message("Error: no JSON results for pull requests by author in project; " \
      "command: #{pulls_by_author_in_project_cmd}")
    exit 1
  end

  pulls_by_author_in_project = JSON.parse(json)
  pull_numbers_by_repo_nwo = pulls_by_author_in_project.each_with_object({}) do |data, hash|
    repo_nwo = data["repository"]["nameWithOwner"]
    hash[repo_nwo] ||= []
    hash[repo_nwo] << data["number"]
  end

  total_project_items_before = project_items.size
  project_items = project_items.select do |item|
    item_repo_nwo = item["content"]["repository"]
    item_pr_number = item["content"]["number"]
    pull_numbers_by_repo_nwo.key?(item_repo_nwo) && pull_numbers_by_repo_nwo[item_repo_nwo].include?(item_pr_number)
  end
  total_project_items_after = project_items.size

  unless quiet_mode
    if total_project_items_before == total_project_items_after
      output_info_message("All PRs in project were authored by @#{project.author}")
    else
      after_units = total_project_items_after == 1 ? "pull request" : "pull requests"
      output_info_message("Filtered PRs in project down to #{total_project_items_after} #{after_units} authored " \
        "by @#{project.author}")
    end
  end
end

def replace_hyphens(str)
  str.split("-").map(&:capitalize).join("")
end

def repo_field_alias_for(owner:, name:)
  "repo#{replace_hyphens(owner)}#{replace_hyphens(name)}"
end

class Repository
  def initialize(gql_data, failing_test_label_name: nil)
    @gql_data = gql_data
    @raw_failing_test_label_name = failing_test_label_name
  end

  def default_branch
    @default_branch ||= @gql_data["defaultBranchRef"]["name"]
  end
end

class PullRequest
  def initialize(data, project:)
    @data = data
    @gql_data = {}
    @repo = nil
    @project = project
  end

  def set_graphql_data(value)
    @gql_data = value
  end

  def set_repo(value)
    @repo = value
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

  def graphql_repo_field_alias
    @graphql_repo_field_alias ||= repo_field_alias_for(owner: repo_owner, name: repo_name)
  end

  def graphql_field_alias
    @graphql_field_alias ||= "pull#{replace_hyphens(repo_owner)}#{replace_hyphens(repo_name)}#{number}"
  end

  def graphql_field
    <<~GRAPHQL
      #{graphql_field_alias}: pullRequest(number: #{number}) {
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
            fieldValueByName(name: "#{@project.status_field}") {
              ... on ProjectV2ItemFieldSingleSelectValue {
                field { ... on ProjectV2SingleSelectField { id } }
                optionId
                name
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
    current_status_option_id == @project.in_progress_option_id
  end

  def has_not_against_main_status?
    current_status_option_id == @project.not_against_main_option_id
  end

  def has_needs_review_status?
    current_status_option_id == @project.needs_review_option_id
  end

  def has_ready_to_deploy_status?
    current_status_option_id == @project.ready_to_deploy_option_id
  end

  def has_conflicting_status?
    current_status_option_id == @project.conflicting_option_id
  end

  def has_ignored_status?
    @project.ignored_option_ids.include?(current_status_option_id)
  end

  def set_in_progress_status
    output_status_change_loading_message(@project.in_progress_option_name) unless quiet_mode?
    set_project_item_status(@project.in_progress_option_id)
  end

  def set_needs_review_status
    output_status_change_loading_message(@project.needs_review_option_name) unless quiet_mode?
    set_project_item_status(@project.needs_review_option_id)
  end

  def set_not_against_main_status
    output_status_change_loading_message(@project.not_against_main_option_name) unless quiet_mode?
    set_project_item_status(@project.not_against_main_option_id)
  end

  def set_ready_to_deploy_status
    output_status_change_loading_message(@project.ready_to_deploy_option_name) unless quiet_mode?
    set_project_item_status(@project.ready_to_deploy_option_id)
  end

  def set_conflicting_status
    output_status_change_loading_message(@project.conflicting_option_name) unless quiet_mode?
    set_project_item_status(@project.conflicting_option_id)
  end

  def apply_label(label_name:)
    output_loading_message("Applying label '#{label_name}' to #{to_s}...") unless quiet_mode?
    `#{gh_path} pr edit #{number} --repo "#{repo_name_with_owner}" --add-label "#{label_name}"`
  end

  def remove_label(label_name:)
    output_loading_message("Removing label '#{label_name}' from #{to_s}...") unless quiet_mode?
    `#{gh_path} pr edit #{number} --repo "#{repo_name_with_owner}" --remove-label "#{label_name}"`
  end

  def rerun_failed_run(run_id:)
    unless quiet_mode?
      build_name = build_name_for_run_id(run_id)
      output_loading_message("Rerunning failed run #{build_name || run_id} for #{to_s}...")
    end
    `#{gh_path} run rerun #{run_id} --failed --repo "#{repo_name_with_owner}"`
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
    output_loading_message("Marking #{to_s} as a draft...") unless quiet_mode?
    `#{gh_path} pr ready --undo #{number} --repo "#{repo_name_with_owner}"`
  end

  def can_mark_as_draft?
    !draft? && !enqueued? && @project.allow_marking_drafts?
  end

  def should_have_in_progress_status?
    return false if has_ignored_status?
    return false unless @project.in_progress_option_id # can't
    return false if enqueued? # don't say it's in progress if we're already in the merge queue

    # If we have a 'Conflicting' column...
    if @project.conflicting_option_id
      return false if conflicting? # don't put PR with merge conflicts into 'In progress'
      return false if unknown_merge_state? # don't assume it's not conflicting if we can't tell
    end

    # If not based on 'main', should be in 'Not against main' if we have such a column
    return false if daisy_chained? && @project.not_against_main_option_id

    if has_needs_review_status? || has_ready_to_deploy_status?
      failing_required_builds? || draft?
    else # Conflicting, Not against main, In progress
      !approved? || draft?
    end
  end

  def should_have_needs_review_status?
    return false if has_ignored_status?
    return false unless @project.needs_review_option_id # can't
    return false if conflicting? # don't ask for review when there are conflicts to resolve
    return false if draft? # don't ask for review if it's still a draft
    return false if daisy_chained? # don't ask for review when base branch will change

    # Don't ask for review if we're already in the merge queue and have a 'Ready to deploy' column:
    return false if enqueued? && @project.ready_to_deploy_option_id

    already_approved_check = if @project.ready_to_deploy_option_id
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
    return false unless @project.not_against_main_option_id # can't
    daisy_chained?
  end

  def should_have_ready_to_deploy_status?
    return false if has_ignored_status?
    return false unless @project.ready_to_deploy_option_id # can't
    !draft? && enqueued?
  end

  def should_have_conflicting_status?
    return false if has_ignored_status?
    return false unless @project.conflicting_option_id # can't
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
    json_str = `#{gh_path} pr checks #{number} --repo "#{repo_name_with_owner}" --required --json "link,state,name"`
    json_str.nil? || json_str.size < 1 ? [] : JSON.parse(json_str)
  end

  def failing_test_label_name
    @project.failing_test_label_name
  end

  def build_names_for_rerun
    @project.build_names_for_rerun
  end

  def last_commit
    return @last_commit if defined?(@last_commit)
    node = @gql_data["commits"]["nodes"][0]
    @last_commit = if node
      node["commit"]
    end
  end

  def set_project_item_status(option_id)
    return false unless option_id
    `#{gh_path} project item-edit --id #{project_item_id} --project-id #{project_global_id} --field-id #{status_field_id} --single-select-option-id #{option_id}`
  end

  def output_status_change_loading_message(target_column_name)
    output_loading_message("Moving #{to_s} out of '#{current_status_option_name}' column to " \
      "'#{target_column_name}'...") unless quiet_mode?
  end

  def quiet_mode?
    @project.quiet_mode?
  end

  def gh_path
    @project.gh_path
  end
end

project_pulls = project_items.map { |pull_info| PullRequest.new(pull_info, project: project) }
pulls_by_repo_owner_and_repo_name = project_pulls.each_with_object({}) do |pull, hash|
  repo_owner = pull.repo_owner
  repo_name = pull.repo_name
  hash[repo_owner] ||= {}
  hash[repo_owner][repo_name] ||= []
  hash[repo_owner][repo_name] << pull
end

def repository_graphql_for(repo_owner:, repo_name:, pull_fields: [])
  field_alias = repo_field_alias_for(owner: repo_owner, name: repo_name)
  <<~GRAPHQL
    #{field_alias}: repository(owner: "#{repo_owner}", name: "#{repo_name}") {
      id
      defaultBranchRef { name }
      #{pull_fields.join("\n")}
    }
  GRAPHQL
end

repo_fields = []

pulls_by_repo_owner_and_repo_name.each do |repo_owner, pulls_by_repo_name|
  total_repos = pulls_by_repo_name.size
  repo_units = total_repos == 1 ? "repository" : "repositories"
  unless quiet_mode
    output_info_message("Found pull requests in #{total_repos} unique #{repo_units} by @#{repo_owner}")
  end

  pulls_by_repo_name.each do |repo_name, pulls_in_repo|
    pull_fields = pulls_in_repo.map(&:graphql_field)
    repo_fields << repository_graphql_for(repo_owner: repo_owner, repo_name: repo_name, pull_fields: pull_fields)
  end
end

output_loading_message("Looking up more info about each pull request in project...") unless quiet_mode
graphql_query = <<~GRAPHQL
  query {
    #{project.owner_graphql_field}
    #{repo_fields.join("\n")}
  }
GRAPHQL
json_str = `#{gh_path} api graphql -f query='#{graphql_query}'`
graphql_resp = JSON.parse(json_str)
graphql_data = graphql_resp["data"]

unless graphql_data
  graphql_error_msg = if graphql_resp["errors"]
    graphql_resp["errors"].map { |err| err["message"] }.join("\n")
  else
    graphql_resp.inspect
  end
  output_error_message("Error: no data returned from the GraphQL API")
  output_error_message(graphql_error_msg)
  exit 1
end

if graphql_data["user"]
  project.set_graphql_data(graphql_data["user"])
elsif graphql_data["organization"]
  project.set_graphql_data(graphql_data["organization"])
end

unless quiet_mode
  output_info_message("'#{project.status_field}' options enabled: #{project.enabled_options.join(', ')}")
  output_info_message("Ignored '#{project.status_field}' options: #{project.ignored_option_names.join(', ')}")
end

project_pulls.each do |pull|
  repo_gql_data = graphql_data[pull.graphql_repo_field_alias]
  next unless repo_gql_data

  repo = Repository.new(repo_gql_data, failing_test_label_name: failing_test_label_name)
  pull.set_repo(repo)

  extra_info = repo_gql_data[pull.graphql_field_alias]
  pull.set_graphql_data(extra_info) if extra_info
end

output_success_message("Loaded extra pull request info from the API") unless quiet_mode

total_status_changes_by_new_status = Hash.new(0)
total_labels_applied_by_name = Hash.new(0)
total_labels_removed_by_name = Hash.new(0)

project_pulls.each do |pull|
  new_pull_status_option_name = pull.change_status_if_necessary
  if new_pull_status_option_name
    total_status_changes_by_new_status[new_pull_status_option_name] += 1
  end

  applied_label_name = pull.apply_label_if_necessary
  if applied_label_name
    total_labels_applied_by_name[applied_label_name] += 1
  end

  removed_label_name = pull.remove_label_if_necessary
  if removed_label_name
    total_labels_removed_by_name[removed_label_name] += 1
  end
end

any_changes = (total_status_changes_by_new_status.values.sum +
  total_labels_applied_by_name.values.sum +
  total_labels_removed_by_name.values.sum) > 0

if any_changes
  message_pieces = []

  total_status_changes_by_new_status.each do |new_status, count|
    units = count == 1 ? "pull request" : "pull requests"
    first_letter = message_pieces.size < 1 ? "M" : "m"
    message_pieces << "#{first_letter}oved #{count} #{units} to '#{new_status}'"
  end

  total_labels_applied_by_name.each do |label_name, count|
    units = count == 1 ? "pull request" : "pull requests"
    first_letter = message_pieces.size < 1 ? "A" : "a"
    message_pieces << "#{first_letter}pplied '#{label_name}' to #{count} #{units}"
  end

  total_labels_removed_by_name.each do |label_name, count|
    units = count == 1 ? "pull request" : "pull requests"
    first_letter = message_pieces.size < 1 ? "R" : "r"
    message_pieces << "#{first_letter}emoved '#{label_name}' from #{count} #{units}"
  end

  message = message_pieces.join(", ")
  output_info_message(message) unless quiet_mode
  send_desktop_notification(content: message, title: project.title)
else
  output_info_message("No pull requests needed a different status or a label change") unless quiet_mode
end
