#!/usr/bin/env ruby

require "octokit"
require "optparse"

options = {}
option_parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{__FILE__} [options]"
  opts.on("-p NUM", "--project-number", Integer,
    "Project number (required), e.g., 123 for https://github.com/orgs/someorg/projects/123")
  opts.on("-o OWNER", "--project-owner", String,
    "Project owner login (required), e.g., someorg for https://github.com/orgs/someorg/projects/123")
  opts.on("-s STATUS", "--status-field", String,
    "Status field name, name of a single-select field in the project")
  opts.on("-i ID", "--in-progress", String, "Option ID of 'In progress' column")
  opts.on("-a ID", "--not-against-main", String, "Option ID of 'Not against main' column")
  opts.on("-n ID", "--needs-review", String, "Option ID of 'Needs review' column")
  opts.on("-r ID", "--ready-to-deploy", String, "Option ID of 'Ready to deploy' column")
  opts.on("-c ID", "--conflicting", String, "Option ID of 'Conflicting' column")
  opts.on("-g IDS", "--ignored", Array,
    "Comma-separated list of option IDs of columns like 'Blocked' or 'On hold'")
end
option_parser.parse!(into: options)

class Project
  def initialize(options)
    @options = options
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

  def in_progress_option_id
    @in_progress_option_id ||= @options[:"in-progress"]
  end

  def not_against_main_option_id
    @not_against_main_option_id ||= @options[:"not-against-main"]
  end

  def needs_review_option_id
    @needs_review_option_id ||= @options[:"needs-review"]
  end

  def ready_to_deploy_option_id
    @ready_to_deploy_option_id ||= @options[:"ready-to-deploy"]
  end

  def conflicting_option_id
    @conflicting_option_id ||= @options[:"conflicting"]
  end

  def ignored_option_ids
    @ignored_option_ids ||= @options[:"ignored"] || []
  end
end

project = Project.new(options)

unless project.number && project.owner && project.status_field
  puts option_parser
  exit 1
end

def output_loading_message(content)
  puts "⏳ #{content}"
end

def output_success_message(content)
  puts "✅ #{content}"
end

def output_info_message(content)
  puts "ℹ️ #{content}"
end

output_loading_message("Authenticating with GitHub...")
token = `gh auth token`
client = Octokit::Client.new(access_token: token)
username = client.user[:login]
output_success_message("Authenticated as GitHub user @#{username}")

output_loading_message("Looking up items in project #{project.number} owned by @#{project.owner}...")
json = `gh project item-list #{project.number} --owner #{project.owner} --format json`
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
    @gql_data["mergeable"]
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
    output_status_change_loading_message("In progress")
    set_project_item_status(@project.in_progress_option_id)
  end

  def set_needs_review_status
    output_status_change_loading_message("Needs review")
    set_project_item_status(@project.needs_review_option_id)
  end

  def set_not_against_main_status
    output_status_change_loading_message("Not against main")
    set_project_item_status(@project.not_against_main_option_id)
  end

  def set_ready_to_deploy_status
    output_status_change_loading_message("Ready to deploy")
    set_project_item_status(@project.ready_to_deploy_option_id)
  end

  def set_conflicting_status
    output_status_change_loading_message("Conflicting")
    set_project_item_status(@project.conflicting_option_id)
  end

  def mark_as_draft
    output_loading_message("Marking #{to_s} as a draft...")
    `gh pr ready --undo #{number} --repo "#{repo_name_with_owner}"`
  end

  def can_mark_as_draft?
    !draft? && !enqueued?
  end

  def should_set_in_progress_status?
    return false unless @project.in_progress_option_id # can't
    return false if has_in_progress_status? # no-op
    return false if enqueued? # don't say it's in progress if we're already in the merge queue
    return false if conflicting? # don't put PR with merge conflicts into 'In progress'

    if has_needs_review_status? || has_ready_to_deploy_status?
      failing_required_check_suites? || failing_required_statuses?
    else
      against_default_branch? && !has_ignored_status?
    end
  end

  def should_set_needs_review_status?
    return false unless @project.needs_review_option_id # can't
    return false if has_needs_review_status? # no-op
    return false if conflicting? # don't ask for review when there are conflicts to resolve
    return false if draft? # don't ask for review if it's still a draft
    return false unless against_default_branch? # don't ask for review when base branch will change
    return false if enqueued? # don't ask for review if we're already in the merge queue

    !approved? && (has_in_progress_status? || has_conflicting_status? || has_ready_to_deploy_status?)
  end

  def should_set_not_against_main_status?
    return false unless @project.not_against_main_option_id
    return false if has_not_against_main_status?
    !against_default_branch? && !has_ignored_status?
  end

  def should_set_ready_to_deploy_status?
    return false unless @project.ready_to_deploy_option_id
    return false if has_ready_to_deploy_status?
    !draft? && enqueued? && !has_ignored_status?
  end

  def should_set_conflicting_status?
    return false unless @project.conflicting_option_id
    return false if has_conflicting_status?
    against_default_branch? && conflicting? && !enqueued? && !has_ignored_status?
  end

  def change_status_if_necessary
    if should_set_in_progress_status?
      set_in_progress_status
      mark_as_draft if can_mark_as_draft?
      return true
    end

    if should_set_needs_review_status?
      set_needs_review_status
      return true
    end

    if should_set_not_against_main_status?
      set_not_against_main_status
      mark_as_draft if can_mark_as_draft?
      return true
    end

    if should_set_ready_to_deploy_status?
      set_ready_to_deploy_status
      return true
    end

    if should_set_conflicting_status?
      set_conflicting_status
      mark_as_draft if can_mark_as_draft?
      return true
    end

    false
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
    `gh project item-edit --id #{project_item_id} --project-id #{project_global_id} --field-id #{status_field_id} --single-select-option-id #{option_id}`
  end

  def output_status_change_loading_message(target_column_name)
    output_loading_message("Moving #{to_s} out of #{current_status_option_name} column to '#{target_column_name}'...")
  end
end

project_pulls = project_items.select { |item| item["content"]["type"] == "PullRequest" }
  .map { |pull_info| PullRequest.new(pull_info, project: project) }
total_pulls = project_pulls.size
pull_units = total_pulls == 1 ? "pull request" : "pull requests"
output_success_message("Found #{total_pulls} #{pull_units} in project")

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
  output_info_message("Found pull requests in #{total_repos} unique #{repo_units} by @#{repo_owner}")

  pulls_by_repo_name.each do |repo_name, pulls_in_repo|
    pull_fields = pulls_in_repo.map(&:graphql_field)
    repo_fields << repository_graphql_for(repo_owner: repo_owner, repo_name: repo_name, pull_fields: pull_fields)
  end
end

output_loading_message("Looking up more info about each pull request in project...")
json = `gh api graphql -f query='query { #{repo_fields.join("\n")} }'`
project_pull_info_by_repo_field_alias = JSON.parse(json)["data"]

project_pulls.each do |pull|
  repo_gql_data = project_pull_info_by_repo_field_alias[pull.graphql_repo_field_alias]
  next unless repo_gql_data

  repo = Repository.new(repo_gql_data)
  pull.set_repo(repo)

  extra_info = repo_gql_data[pull.graphql_field_alias]
  pull.set_graphql_data(extra_info) if extra_info
end

output_success_message("Loaded extra pull request info")

total_status_changes = 0
project_pulls.each do |pull|
  if pull.change_status_if_necessary
    total_status_changes += 1
  end
end

if total_status_changes < 1
  output_info_message("No pull requests needed a different status")
else
  units = total_status_changes == 1 ? "pull request" : "pull requests"
  output_info_message("Updated status for #{total_status_changes} #{units}")
end
