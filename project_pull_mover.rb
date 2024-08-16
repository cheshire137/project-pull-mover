#!/usr/bin/env ruby
# encoding: utf-8

require "json"
require "optparse"

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

  def quiet_mode?
    @options[:quiet]
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
    result.concat(ignored_option_names)
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

project_items_cmd = "#{gh_path} project item-list #{project.number} --owner #{project.owner} --format json"
json = `#{project_items_cmd}`
if json.nil? || json == ""
  output_error_message("Error: no JSON results for project items; command: #{project_items_cmd}")
  exit 1
end

project_items = JSON.parse(json)["items"]

def replace_hyphens(str)
  str.split("-").map(&:capitalize).join("")
end

def repo_field_alias_for(owner:, name:)
  "repo#{replace_hyphens(owner)}#{replace_hyphens(name)}"
end

class Repository
  def initialize(gql_data)
    @gql_data = gql_data
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

  def mark_as_draft
    output_loading_message("Marking #{to_s} as a draft...") unless quiet_mode?
    `#{gh_path} pr ready --undo #{number} --repo "#{repo_name_with_owner}"`
  end

  def can_mark_as_draft?
    !draft? && !enqueued?
  end

  def should_set_in_progress_status?
    return false unless @project.in_progress_option_id # can't
    return false if has_in_progress_status? # no-op
    return false if enqueued? # don't say it's in progress if we're already in the merge queue
    return false if conflicting? # don't put PR with merge conflicts into 'In progress'
    return false if unknown_merge_state? # don't assume it's not conflicting if we can't tell
    return false if daisy_chained? # if not based on 'main', should be in 'Not against main'

    if has_needs_review_status? || has_ready_to_deploy_status?
      failing_required_check_suites? || failing_required_statuses?
    else
      !has_ignored_status?
    end
  end

  def should_set_needs_review_status?
    return false unless @project.needs_review_option_id # can't
    return false if has_needs_review_status? # no-op
    return false if conflicting? # don't ask for review when there are conflicts to resolve
    return false if draft? # don't ask for review if it's still a draft
    return false if daisy_chained? # don't ask for review when base branch will change
    return false if enqueued? # don't ask for review if we're already in the merge queue

    !approved? && (has_in_progress_status? || has_conflicting_status? || has_ready_to_deploy_status?)
  end

  def should_set_not_against_main_status?
    return false unless @project.not_against_main_option_id # can't
    return false if has_not_against_main_status? # no-op
    daisy_chained? && !has_ignored_status?
  end

  def should_set_ready_to_deploy_status?
    return false unless @project.ready_to_deploy_option_id # can't
    return false if has_ready_to_deploy_status? # no-op
    !draft? && enqueued? && !has_ignored_status?
  end

  def should_set_conflicting_status?
    return false unless @project.conflicting_option_id # can't
    return false if has_conflicting_status? # no-op
    against_default_branch? && conflicting? && !enqueued? && !has_ignored_status?
  end

  def change_status_if_necessary
    if should_set_conflicting_status?
      set_conflicting_status
      mark_as_draft if can_mark_as_draft?
      return @project.conflicting_option_name
    end

    if should_set_not_against_main_status?
      set_not_against_main_status
      mark_as_draft if can_mark_as_draft?
      return @project.not_against_main_option_name
    end

    if should_set_ready_to_deploy_status?
      set_ready_to_deploy_status
      return @project.ready_to_deploy_option_name
    end

    if should_set_needs_review_status?
      set_needs_review_status
      return @project.needs_review_option_name
    end

    if should_set_in_progress_status?
      set_in_progress_status
      mark_as_draft if can_mark_as_draft?
      return @project.in_progress_option_name
    end

    nil
  end

  private

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

project_pulls = project_items.select { |item| item["content"]["type"] == "PullRequest" }
  .map { |pull_info| PullRequest.new(pull_info, project: project) }
total_pulls = project_pulls.size
pull_units = total_pulls == 1 ? "pull request" : "pull requests"
output_success_message("Found #{total_pulls} #{pull_units} in project") unless quiet_mode

pulls_by_repo_owner_and_repo_name = project_pulls.each_with_object({}) do |pull, hash|
  repo_owner = pull.repo_owner
  repo_name = pull.repo_name
  hash[repo_owner] ||= {}
  hash[repo_owner][repo_name] ||= []
  hash[repo_owner][repo_name] << pull
end

def repository_graphql_for(repo_owner:, repo_name:, pull_fields:)
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
json = `#{gh_path} api graphql -f query='#{graphql_query}'`
graphql_data = JSON.parse(json)["data"]

if graphql_data["user"]
  project.set_graphql_data(graphql_data["user"])
elsif graphql_data["organization"]
  project.set_graphql_data(graphql_data["organization"])
end

unless quiet_mode
  output_info_message("'#{project.status_field}' options enabled: #{project.enabled_options.join(', ')}")
end

project_pulls.each do |pull|
  repo_gql_data = graphql_data[pull.graphql_repo_field_alias]
  next unless repo_gql_data

  repo = Repository.new(repo_gql_data)
  pull.set_repo(repo)

  extra_info = repo_gql_data[pull.graphql_field_alias]
  pull.set_graphql_data(extra_info) if extra_info
end

output_success_message("Loaded extra pull request info") unless quiet_mode

total_status_changes_by_new_status = Hash.new(0)
project_pulls.each do |pull|
  new_pull_status_option_name = pull.change_status_if_necessary
  if new_pull_status_option_name
    total_status_changes_by_new_status[new_pull_status_option_name] += 1
  end
end

if total_status_changes_by_new_status.values.sum < 1
  output_info_message("No pull requests needed a different status") unless quiet_mode
else
  message_pieces = []
  total_status_changes_by_new_status.each do |new_status, count|
    units = count == 1 ? "pull request" : "pull requests"
    first_letter = message_pieces.size < 1 ? "M" : "m"
    message_pieces << "#{first_letter}oved #{count} #{units} to '#{new_status}'"
  end
  message = message_pieces.join(", ")
  output_info_message(message) unless quiet_mode
  send_desktop_notification(content: message, title: project.title)
end
