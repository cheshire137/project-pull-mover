#!/usr/bin/env ruby
# encoding: utf-8
#
# This script is designed to be used with GitHub projects that have a single-select field for status tracking.
# It will move pull requests between columns based on the status of the pull request's required checks, whether
# the pull request has conflicting changes, whether the pull request is in the merge queue, and other factors.
# It will also update the 'draft' state of a pull request and apply or remove a label to indicate test failures.

require "digest"
require "json"
require "optparse"
require "set"
require_relative "utils"
require_relative "project"
require_relative "repository"
require_relative "pull_request"

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

proj_items_limit = 500
pull_fields_per_query = 7
project = Project.new(options)
gh_path = project.gh_path

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

unless quiet_mode
  auth_status_result = `#{gh_path} auth status`
  output_info_message(auth_status_result.force_encoding("UTF-8"))
end

unless quiet_mode
  output_loading_message("Looking up items in project #{project.number} owned by @#{project.owner}...")
end

project_items_cmd = "#{gh_path} project item-list #{project.number} --owner #{project.owner} --format json " \
  "--limit #{proj_items_limit}"
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
    "\"#{project.owner}/#{project.number}\" --json \"number,repository\" --limit #{proj_items_limit} --state open"
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

project_pulls = project_items.map { |pull_info| PullRequest.new(pull_info, project: project) }

output_loading_message("Looking up more info about each pull request in project...") unless quiet_mode
graphql_queries = []
graphql_data = {}
pull_fields = project_pulls.map(&:graphql_field)

graphql_queries << <<~GRAPHQL
  query {
    #{project.owner_graphql_field}
    #{pull_fields.take(pull_fields_per_query).join("\n")}
  }
GRAPHQL

remaining_pull_fields = pull_fields.drop(pull_fields_per_query)
remaining_pull_fields.each_slice(pull_fields_per_query) do |pull_fields_in_batch|
  graphql_queries << <<~GRAPHQL
    query {
      #{pull_fields_in_batch.join("\n")}
    }
  GRAPHQL
end

output_info_message("Will make #{graphql_queries.size} API request(s) to get pull request data") unless quiet_mode

graphql_queries.each_with_index do |graphql_query, query_index|
  output_loading_message("Making API request #{query_index + 1} of #{graphql_queries.size}...") unless quiet_mode
  json_str = `#{gh_path} api graphql -f query='#{graphql_query}'`
  graphql_resp = JSON.parse(json_str)

  if graphql_resp["data"]
    graphql_data.merge!(graphql_resp["data"])
  else
    graphql_error_msg = if graphql_resp["errors"]
      graphql_resp["errors"].map { |err| err["message"] }.join("\n")
    else
      graphql_resp.inspect
    end
    output_error_message("Error: no data returned from the GraphQL API")
    output_error_message(graphql_error_msg)
    exit 1
  end
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
  extra_info = graphql_data[pull.graphql_field_alias]
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
