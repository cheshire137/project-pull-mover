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

options[:"status-field"] ||= "Status"
pp options
project_number = options[:"project-number"]
project_owner = options[:"project-owner"]

unless project_number && project_owner
  puts option_parser
  exit 1
end

puts "Working with project #{project_number} owned by @#{project_owner}"
token = `gh auth token`
client = Octokit::Client.new(access_token: token)
username = client.user[:login]
puts "Authenticated as GitHub user @#{username}"

json = `gh project item-list #{project_number} --owner #{project_owner} --format json`
project_items = JSON.parse(json)["items"]
project_pulls = project_items.select { |item| item["content"]["type"] == "PullRequest" }
total_pulls = project_pulls.size
pull_units = total_pulls == 1 ? "pull request" : "pull requests"
puts "Found #{total_pulls} #{pull_units} in project"

pulls_by_repo_owner_and_repo_name = project_pulls.each_with_object({}) do |pull, hash|
  repo_name_with_owner = pull["content"]["repository"]
  repo_owner, repo_name = repo_name_with_owner.split("/")
  hash[repo_owner] ||= {}
  hash[repo_owner][repo_name] ||= []
  hash[repo_owner][repo_name] << pull
end

def replace_hyphens(str)
  str.split("-").map(&:capitalize).join("")
end

def pull_request_field_alias_for(repo_owner:, repo_name:, number:)
  "pull#{replace_hyphens(repo_owner)}#{replace_hyphens(repo_name)}#{number}"
end

def pull_request_graphql_for(field_alias:, number:, status_field_name:)
  <<~GRAPHQL
    #{field_alias}: pullRequest(number: #{number}) {
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
          fieldValueByName(name: "#{status_field_name}") {
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

def repo_field_alias_for(owner:, name:)
  "repo#{replace_hyphens(owner)}#{replace_hyphens(name)}"
end

def repository_graphql_for(repo_owner:, repo_name:, pull_fields:)
  field_alias = repo_field_alias_for(owner: repo_owner, name: repo_name)
  <<~GRAPHQL
    #{field_alias}: repository(owner: "#{repo_owner}", name: "#{repo_name}") {
      id
      #{pull_fields.join("\n")}
    }
  GRAPHQL
end

repo_fields = []
status_field_name = options[:"status-field"]

pulls_by_repo_owner_and_repo_name.each do |repo_owner, pulls_by_repo_name|
  total_repos = pulls_by_repo_name.size
  repo_units = total_repos == 1 ? "repository" : "repositories"
  puts "Found pull requests in #{total_repos} unique #{repo_units} by @#{repo_owner}"

  pulls_by_repo_name.each do |repo_name, pulls_in_repo|
    pull_fields = pulls_in_repo.map do |pull|
      pull_number = pull["content"]["number"]
      pull_field_alias = pull_request_field_alias_for(repo_owner: repo_owner, repo_name: repo_name,
        number: pull_number)
      pull_request_graphql_for(field_alias: pull_field_alias, number: pull_number,
        status_field_name: status_field_name)
    end

    repo_fields << repository_graphql_for(repo_owner: repo_owner, repo_name: repo_name,
      pull_fields: pull_fields)
  end
end

graphql_query = <<~GRAPHQL
  query {
    #{repo_fields.join("\n")}
  }
GRAPHQL
puts graphql_query
