#!/usr/bin/env ruby
# typed: false
# encoding: utf-8

require "optparse"
require "json"
require_relative "utils"

options = {}
option_parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{__FILE__} [options]"
  opts.on("-h PATH", "--gh-path", String, "Path to gh executable")
  opts.on("-u AUTHOR", "--author", String, "Specify a username so that only PRs authored by that user are changed")
end
option_parser.parse!(into: options)

author = options[:"author"]
if author.nil? || author.strip.size < 1
  output_error_message("Author is required")
  puts option_parser
  exit 1
end

gh_path = options[:"gh-path"] || which("gh") || "gh"
quiet_mode = options[:quiet]
pulls_limit = 500
pull_fields_per_query = 7

output_loading_message("Looking up pull requests owned by @#{author}...")
pulls_by_author_cmd = "#{gh_path} search prs --author \"#{author}\" --json \"number,repository\" --limit " \
  "#{pulls_limit} --state open"
json = `#{pulls_by_author_cmd}`
if json.nil? || json == ""
  output_error_message("Error: no JSON results for pull requests by author; command: #{pulls_by_author_cmd}")
  exit 1
end

pull_numbers_by_repo_nwo = JSON.parse(json).each_with_object({}) do |data, hash|
  repo_nwo = data["repository"]["nameWithOwner"]
  hash[repo_nwo] ||= []
  hash[repo_nwo] << data["number"]
end

unless quiet_mode
  if pull_numbers_by_repo_nwo.empty?
    output_info_message("No pull requests found for @#{author}")
    output_success_message("Done!")
    exit 0
  end

  pull_numbers_by_repo_nwo.each do |repo_nwo, pull_numbers|
    units = pull_numbers.size == 1 ? "pull request" : "pull requests"
    output_info_message("Found #{pull_numbers.size} #{units} in #{repo_nwo}")
  end
end

pull_graphql_fields = []
pull_numbers_by_repo_nwo.each do |repo_nwo, pull_numbers|
  repo_owner, repo_name = repo_nwo.split("/")
  graphql_field_alias_prefix = "pull#{replace_hyphens(repo_owner)}#{replace_hyphens(repo_name)}"
  pull_numbers.each do |number|
    graphql_field_alias = "#{graphql_field_alias_prefix}#{number}"
    graphql_field = <<~GRAPHQL
      #{graphql_field_alias}: repository(owner: "#{repo_owner}", name: "#{repo_name}") {
        pullRequest(number: #{number}) {
          isDraft
          mergeable
        }
      }
    GRAPHQL
    pull_graphql_fields << graphql_field
  end
end

graphql_data = {}
graphql_queries = []
graphql_queries << <<~GRAPHQL
  query {
    #{pull_graphql_fields.take(pull_fields_per_query).join("\n")}
  }
GRAPHQL
remaining_pull_fields = pull_graphql_fields.drop(pull_fields_per_query)
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

pp graphql_data
